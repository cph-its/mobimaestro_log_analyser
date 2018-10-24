
-- create table
DROP TABLE IF EXISTS events;
CREATE TABLE events
(
  id serial NOT NULL,
  at timestamp,
  object character varying(255),
  event character varying(255),
  description character varying(255),
  CONSTRAINT events_pkey PRIMARY KEY (id)
);

-- import from CSV
COPY events(at,object,event,description) FROM '/docker-entrypoint-initdb.d/events.csv' DELIMITER ';' CSV HEADER;

-- analyze and output to table
SELECT
object,
split_part(object,'-',2) AS ag,
split_part(object,'-',3) AS type,
split_part(object,'-',4) AS manufacturer,
split_part(object,'-',5) AS nr,
COUNT(duration) AS num,
ROUND( CAST( 100-(100*date_part('epoch', SUM(duration))/(60*60*24*30)) AS numeric), 2) AS uptime,
date_part('epoch', SUM(duration)) AS sum,
ROUND(date_part('epoch',AVG(duration))) AS avg,
date_part('epoch', MAX(duration)) AS max,
ROUND( CAST( stddev_samp(EXTRACT(EPOCH FROM duration)) AS numeric), 2) AS std_dev
INTO TABLE stats
FROM
	(SELECT
	id,
	object,
	lag(at, 1) OVER (PARTITION BY object ORDER BY at) AS starting,
	at AS ending,
	at - lag(at, 1) OVER (PARTITION BY object ORDER BY at) AS duration,
	event,
	lag(event, 1) OVER (PARTITION BY object ORDER BY at) AS prev_event
	FROM events
	ORDER BY object, at) AS disconnects
WHERE duration IS NOT NULL AND
event = 'Connected' AND
prev_event LIKE '%Disconnected%'
GROUP BY object
ORDER BY ag DESC;

-- export to CSV
COPY (SELECT * from stats ORDER BY ag)TO '/docker-entrypoint-initdb.d/result.csv' DELIMITER ',' CSV HEADER;


