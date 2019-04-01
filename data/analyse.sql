

-- create table
DROP TABLE IF EXISTS events;
CREATE TABLE events
(
  id serial NOT NULL,
  at timestamp,
  type character varying(255),
  object character varying(255),
  event character varying(255),
  description character varying(255),
  CONSTRAINT events_pkey PRIMARY KEY (id)
);

-- import from CSV
COPY events(at,type,object,event,description) FROM '/docker-entrypoint-initdb.d/events.csv' DELIMITER ';' CSV HEADER;


CREATE INDEX idx_events_at ON events(at);
CREATE INDEX idx_events_type ON events(type);
CREATE INDEX idx_events_object ON events(object);
CREATE INDEX idx_events_event ON events(event);


-- guess first and last month
-- note: this will be wrong if there are no events in one or or more of the first/last months
DROP TABLE IF EXISTS range;
SELECT
date_part('year',min(at)) AS first_year,
date_part('month',min(at)) AS first_month,
date_part('year',max(at)) AS last_year,
date_part('month',max(at)) AS last_month,
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
	DATE_PART('year',at) AS year,
	DATE_PART('month',at) AS month,
	split_part(object,'-',2) AS ag,
	split_part(object,'-',3) AS type_code,
	split_part(object,'-',4) AS manufacturer,
	split_part(object,'-',5) AS nr,	
	lag(at, 1) OVER w AS starting,
	at AS ending,
	justify_interval(at - lag(at, 1) OVER w) AS duration,
	lag(event, 1) OVER w AS prev_event,
	event
	FROM events
	WINDOW w AS (PARTITION BY object ORDER BY at)
	ORDER BY object, at) AS disconnects
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


-- split downtime periods on month boundaries
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
	date_trunc('month', starting::timestamp),
	date_trunc('month', ending::timestamp),
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
			date_part('epoch', SUM(duration))/ (		-- total downtime in seconds
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
object,
year,
month,
ROUND(
	CAST(
		100-(100*
			date_part('epoch', SUM(duration))/ (		-- total downtime in seconds
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
GROUP BY year,month,object,type
ORDER BY type,object,year,month;


-- devices where the last event was a disconnect
DROP TABLE IF EXISTS by_last_seen;
SELECT *
INTO TABLE by_last_seen
FROM
(SELECT e.type, e.object, e.at, e.event, e.description
FROM (
   SELECT object, max(at) as latest
   FROM events GROUP BY object
) AS x INNER JOIN events AS e ON e.object = x.object AND e.at = x.latest) AS e
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
)
ORDER BY type, at ASC;


-- export to CSV
COPY (SELECT * from by_device ORDER BY type,manufacturer,up_percentage ASC) TO '/docker-entrypoint-initdb.d/by_device.csv' DELIMITER ',' CSV HEADER;
COPY (SELECT * from by_type ORDER BY type) TO '/docker-entrypoint-initdb.d/by_type.csv' DELIMITER ',' CSV HEADER;
COPY (SELECT * from by_month ORDER BY type,year,month) TO '/docker-entrypoint-initdb.d/by_month.csv' DELIMITER ',' CSV HEADER;
COPY (SELECT * from by_device_and_month ORDER BY type,object,year,month) TO '/docker-entrypoint-initdb.d/by_device_and_month.csv' DELIMITER ',' CSV HEADER;
COPY (SELECT * from by_last_seen ORDER BY type, at ASC) TO '/docker-entrypoint-initdb.d/by_last_seen.csv' DELIMITER ',' CSV HEADER;

