# MobiMeastro event log disconnect analyser

## About
This tool analyzes data from MobiMaestro about disconnects of equipment,
to get statistics on the duration of the disconnects.

Analysis is done with PostgreSQL running in a docker container.

For each object (e.g. traffic light) the following is computed:

- number of disconnects
- total time of all disconnects
- average disconnect duration
- maximum disconnect duration
- standard deviation of disconnect duration

The "object" string is split into parts usable for sorting/querying:
AG (intersection), object type, manufacturer and number.

## Input
A .csv file exported from MobiMaestro, containing events about connects and disconnects.
The first is expected to contain a CVS header.
The file must be located at data/events.csv

The Postgres lag() function to compute the
duration between consecutive pairs of disconnect-connect pairs.
Disconnects are expected to be followed by a connect. If several disconnects
occur without a connect inbetween, then only the last disconnect-connect
duration will be used.

Computing uptime percentage requies knowledge about the total duration of the dataset.
This is currently assumed to be 30 days. When you export data from MobiMaestro,
you need to ensure the data actually covers 30 days, or you will have to adjust
the total time used in analyse.sql.


## Output
A .csv file with the result.
The file will contain a CSV header.
The file will be located at data/result.csv

## Usage
You must have docker desktop installed first:
https://www.docker.com/products/docker-desktop

### Just give me the CSV output
Place the input data in data/event.csv, and run:
$ docker run -v `pwd`/data:/docker-entrypoint-initdb.d --rm postgres
Press Control-C to stop the container.
The output will be locatd in data/result.csv.

### Running custom SQL queries
Place the input data in data/event.csv, and run:
$ docker run -v `pwd`/data:/docker-entrypoint-initdb.d --rm -d postgres > container_id
$ docker exec -it `cat container_id` psql -U postgres

Now you're in PostgreSQL, with raw data already import to the "events" table,
and statistics in the "stats" table. You can do any SQL queries you like, eg:

postgres=# select * from stats order by uptime asc;

If you want to output data to CSV, look at analyse.sql to see how it's done.

When done, you might want to exit sql, and perhaps exit the container and stop it:

postgres=# \q
root@71364c7e3116 :/# exit
$ docker stop `cat container_id`

## Details
The tool uses a docker container to run PostgreSQL and perform the analysis. 
The folder data/ is mounted as a volume to read the input and save the output.
The volume is mounted at /docker-entrypoint-initdb.d. Any .sql files in
the folder is run be default by the PostgresSQL iamge after the database
has been initialied. So the file data/analyze.sql will be run when the container
is started.
The file data/analys.sql contains the SQL commands to import the csv file, run
the analysis and store the result in a csv file.


