-- create table
DROP TABLE IF EXISTS events;
CREATE TABLE events
(
  id serial NOT NULL,
  at timestamp,
  at_external timestamp,
  type character varying(255),
  object character varying(255),
  category character varying(255),
  event character varying(255),
  user_name character varying(255),
  description character varying(255),
  year integer,
  month integer,
  ag character varying(255),
  type_code character varying(255),
  manufacturer character varying(255),
  nr character varying(255),

  CONSTRAINT events_pkey PRIMARY KEY (id)
);


-- import from CSV
COPY events(at,at_external,type,object,category,event,user_name,description) FROM '/docker-entrypoint-initdb.d/events.csv' DELIMITER ';' CSV HEADER;

-- extract year and month
UPDATE events SET
year = date_part('year',at),
month = date_part('month',at);

-- split object field, for RSMP devices
UPDATE events SET
ag = split_part(object,'-',2),
type_code = split_part(object,'-',3),
manufacturer = split_part(object,'-',4),
nr = split_part(object,'-',5)
WHERE type IN (
	'RSU Device',
	'ViSense camera',
	'RSMP traffic light',
	'RSMP VMS',
	'Radar',
	'Image display',
	'Counting station'
);


-- create index
CREATE INDEX idx_events_at ON events(at);
CREATE INDEX idx_events_type ON events(type);
CREATE INDEX idx_events_object ON events(object);
CREATE INDEX idx_events_event ON events(event);


-- guess first and last month
-- note: this will be wrong if there are no events in one or or more of the first/last months
DROP TABLE IF EXISTS range;
SELECT
min(year) AS first_year,
min(month) AS first_month,
max(year) AS last_year,
max(month) AS last_month,
date_trunc('month',min(at)) AS starting,
date_trunc('month',max(at)) + interval '1 month' AS ending,
date_trunc('month',max(at)) + interval '1 month' - date_trunc('month',min(at)) AS range,
date_part('epoch', date_trunc('month',max(at)) + interval '1 month' - date_trunc('month',min(at))) AS seconds
INTO TABLE range
FROM events;


-- find pairs of consecutive disconnect-connect pairs for each device
DROP TABLE IF EXISTS downtime;
SELECT
*
INTO TABLE downtime
FROM
	(SELECT
	id,
	type,
	object,
	year,
	month,
	ag,
	type_code,
	manufacturer,
	nr,
	lag(at, 1) OVER w AS starting,
	at AS ending,
	justify_interval(at - lag(at, 1) OVER w) AS duration,
	lag(event, 1) OVER w AS prev_event,
	event
	FROM events
	WINDOW w AS (PARTITION BY object ORDER BY at)
	ORDER BY object, at, id) AS disconnects
WHERE 
duration IS NOT NULL AND
prev_event IN (
	'Disconnected due to fatal error',
	'No communication',
	'Disconnected',
	'Connection problem',
	'RSU communication error',
	'RSU not available'
	'Communication failed',
	'Connection problem',
	'Connection stopped',
	'Connection error',
	'Connect error'
) AND
event IN (
	'Connected',
	'Connection started',
	'Ok',
	'RSU ok'
);


-- add a period each object where the first row is a connect
INSERT INTO downtime (ending, ag, month, object, event)
SELECT * FROM
(
  SELECT DISTINCT ON (object)
  at AS ending,
  ag, month, object, event
  FROM events
  ORDER BY object, at ASC
) AS first_row
WHERE event IN (
  'Connected',
  'Connection started',
  'Ok',
  'RSU ok'
);


-- add a period each object where the last row is a disconnect
INSERT INTO downtime (starting, ag, month, object, event)
SELECT * FROM
(
  SELECT DISTINCT ON (object)
  at AS starting,
  ag, month, object, event
  FROM events
  ORDER BY object, at DESC
  ) AS last_row
WHERE event IN (
  'Disconnected due to fatal error',
  'No communication',
  'Disconnected',
  'Connection problem',
  'RSU communication error',
  'RSU not available'
  'Communication failed',
  'Connection problem',
  'Connection stopped',
  'Connection error',
  'Connect error'
);

-- split downtime periods on month boundaries
-- if a downtime has no start, use the start of the month of the end date
-- if a downtime has no end, use the end of the month of the start date
DROP TABLE IF EXISTS downtime_periods;
SELECT
downtime.object,
downtime.type,
downtime.manufacturer,
downtime.ag,
downtime.type_code,
downtime.nr,
extract('year' FROM period)::int AS year,
extract('month' FROM period)::int AS month,
GREATEST(period, downtime.starting) AS starting,
LEAST(period + interval '1 month', downtime.ending) AS ending,
LEAST(period + interval '1 month', downtime.ending) - GREATEST(period, downtime.starting) AS duration
INTO TABLE downtime_periods
FROM
downtime
LEFT JOIN LATERAL
generate_series(
  date_trunc('month', LEAST(starting::timestamp,ending::timestamp)),
  date_trunc('month', GREATEST(starting::timestamp,ending::timestamp)),
  interval '1 month'
) period ON true
ORDER BY object, starting;

CREATE INDEX idx_downtime_year ON downtime_periods(year);
CREATE INDEX idx_downtime_month ON downtime_periods(month);
CREATE INDEX idx_downtime_type ON downtime_periods(type);
CREATE INDEX idx_downtime_object ON downtime_periods(object);
CREATE INDEX idx_downtime_duration ON downtime_periods(duration);


-- by device
DROP TABLE IF EXISTS by_device;
SELECT
type,
object,
ag,
type_code,
manufacturer,
nr,
COUNT(duration) AS disconnects,
ROUND( CAST( 100-(100*date_part('epoch', SUM(duration))/range.seconds) AS numeric), 2) AS up_percentage,
justify_interval(SUM(duration)) AS sum,
justify_interval(AVG(duration)) AS avg,
justify_interval(MAX(duration)) AS max
INTO TABLE by_device
FROM downtime,range
GROUP BY type,object,ag,type_code,manufacturer,nr,seconds;


-- by device type
DROP TABLE IF EXISTS by_type;
SELECT
type,
COUNT(DISTINCT object) as devices,
ROUND( CAST( 100-(100*date_part('epoch', SUM(duration))/(range.seconds*COUNT(DISTINCT object))) AS numeric), 2) AS up_percentage,
COUNT(type) AS disconnects,
justify_interval(SUM(duration)) AS sum,
justify_interval(AVG(duration)) AS avg,
justify_interval(MAX(duration)) AS max
INTO TABLE by_type
FROM downtime,range
GROUP BY type,seconds;

-- by device type and manufacturer
DROP TABLE IF EXISTS by_type_and_manufacturer;
SELECT
type,
manufacturer,
COUNT(DISTINCT object) as devices,
ROUND( CAST( 100-(100*date_part('epoch', SUM(duration))/(range.seconds*COUNT(DISTINCT object))) AS numeric), 2) AS up_percentage,
COUNT(type) AS disconnects,
COUNT(type)/COUNT(DISTINCT object) AS "disconnects/device",
justify_interval(SUM(duration)) AS sum,
justify_interval(AVG(duration)) AS avg,
justify_interval(MAX(duration)) AS max
INTO TABLE by_type_and_manufacturer
FROM downtime,range
GROUP BY type,manufacturer,seconds;

-- FIXME: we need a list of devices to corectly compute averages.
-- by months and type
DROP TABLE IF EXISTS by_month;
SELECT
type,
manufacturer,
year,
month,
COUNT(DISTINCT object) as devices,
ROUND(
  CAST(
    100-(100*
      date_part('epoch', SUM(duration))/ (    -- total downtime in seconds
      60*60*24 * -- seconds per day
      extract(days FROM make_date(year::INTEGER,month::INTEGER,1) + interval '1 month' - interval '1 day') * -- days in month
      COUNT(DISTINCT object) -- number of devices
    )
  ) AS numeric),
  2
) AS up_percentage,
COUNT(type) AS disconnects,
justify_interval(AVG(duration)) AS avg_duration,
justify_interval(MAX(duration)) AS max_duration
INTO TABLE by_month
FROM downtime_periods
GROUP BY year,month,type,manufacturer
ORDER BY type,manufacturer,year,month;


-- by months and device
DROP TABLE IF EXISTS by_device_and_month;
SELECT
type,
manufacturer,
ag,
object,
year,
month,
ROUND(
  CAST(
    100-(100*
      date_part('epoch', SUM(duration))/ (    -- total downtime in seconds
      60*60*24 * -- seconds per day
      extract(days FROM make_date(year::INTEGER,month::INTEGER,1) + interval '1 month' - interval '1 day') -- days in month
    )
  ) AS numeric),
  2
) AS up_percentage,
COUNT(type) AS disconnects,
justify_interval(SUM(duration)) AS sum,
justify_interval(AVG(duration)) AS avg,
justify_interval(MAX(duration)) AS max
INTO TABLE by_device_and_month
FROM downtime_periods
GROUP BY year,month,object,type,manufacturer,ag
ORDER BY type,object,year,month;


-- devices where the last event was a disconnect
DROP TABLE IF EXISTS by_last_seen;
SELECT type,object,event,description,at
INTO TABLE by_last_seen
FROM
(
	SELECT
	DISTINCT ON (object)
	type,object,event,description,at,id
	FROM events
	ORDER BY object, at DESC, id DESC
) AS e
WHERE event IN (
  'Disconnected due to fatal error',
  'No communication',
  'Disconnected',
  'Connection problem',
  'RSU communication error',
  'RSU not available'
  'Communication failed',
  'Connection problem',
  'Connection stopped',
  'Connection error',
  'Connect error'
);


-- export to CSV
-- Excel doesn't know how to handle durations,
-- so as part of the export, we export all duratrion as number of seconds as well

COPY (
  SELECT *,
  ROUND(EXTRACT(epoch FROM sum)) AS sum_sec,
  ROUND(EXTRACT(epoch FROM avg)) AS avg_sec,
  ROUND(EXTRACT(epoch FROM max)) AS max_sec
  FROM by_device ORDER BY type,manufacturer,up_percentage ASC
) TO '/docker-entrypoint-initdb.d/by_device.csv' DELIMITER ',' CSV HEADER;

COPY (
  SELECT *,
  ROUND(EXTRACT(epoch FROM sum)) AS sum_sec,
  ROUND(EXTRACT(epoch FROM avg)) AS avg_sec,
  ROUND(EXTRACT(epoch FROM max)) AS max_sec
  FROM by_type ORDER BY type
) TO '/docker-entrypoint-initdb.d/by_type.csv' DELIMITER ',' CSV HEADER;

COPY (
  SELECT *,
  ROUND(EXTRACT(epoch FROM avg_duration)) AS avg_duration_sec,
  ROUND(EXTRACT(epoch FROM max_duration)) AS max_duration_sec
  FROM by_month ORDER BY type,year,month
) TO '/docker-entrypoint-initdb.d/by_month.csv' DELIMITER ',' CSV HEADER;

COPY (
  SELECT *,
  ROUND(EXTRACT(epoch FROM sum)) AS sum_sec,
  ROUND(EXTRACT(epoch FROM avg)) AS avg_sec,
  ROUND(EXTRACT(epoch FROM max)) AS max_sec
  FROM by_device_and_month ORDER BY type,object,year,month
) TO '/docker-entrypoint-initdb.d/by_device_and_month.csv' DELIMITER ',' CSV HEADER;

COPY (
  SELECT *
  FROM by_last_seen ORDER BY type, at ASC
) TO '/docker-entrypoint-initdb.d/by_last_seen.csv' DELIMITER ',' CSV HEADER;

