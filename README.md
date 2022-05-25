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
The file is expected to contain a CVS header.
The file must be located at data/events.csv

From MobiMaestro, select System > Event History. Select the "Disconnect analysis" filter and load it. If you don't have this filter, you need to set up a filter that includes all the equipment and system types you're interested in, and all connect and disconenct events for these types of equipment/systems.

Make sure the following columns are shown, and nothing else, and in the correct order:
Timestamp, Object Type, Object,  Event, Description.

Then click "Search", and then "Export results..." to save as a .csv file.

## Output
A .csv file with the result.
The file will contain a CSV header.
The file will be located at data/result.csv

## Usage

### Prerequisites
You must have docker desktop installed and running:
https://www.docker.com/products/docker-desktop

On Windows, you must open Docker settings, and go to Shared Drives and active the drive where the
files are located (typically C).

### Dataset time range
Computing uptime percentage requires knowledge about the time range of the dataset.

All datasets are expected to cover whole months. Make sure this is true when you export from MobiMaestro.

### Just give me the CSV output

Linux/Mac:
```
docker run -v `pwd`/data:/docker-entrypoint-initdb.d --rm -e POSTGRES_PASSWORD=1234 postgres
```
Press Control-C to stop the container. (Cntr-C on Windows)


Windows:
Run this in PowerShell:
```
docker run -v `pwd`\data:/docker-entrypoint-initdb.d --rm -e POSTGRES_PASSWORD=1234 postgres
```
Press Cntr-C to stop the container.

Note that Windows uses backslash instead of slash as path separater, but the part after the colon use a slash, since it's a path inside the Linux container.


The output will be located in data/result.csv.

### Running custom SQL queries
Linux/Mac:
```
docker run -v `pwd`/data:/docker-entrypoint-initdb.d --rm  -e POSTGRES_PASSWORD=1234 -d postgres > container_id
docker exec -it `cat container_id` psql -U postgres
```

Windows:
Run this in PowerShell:
```
docker run -v `pwd`\data:/docker-entrypoint-initdb.d --rm  -e POSTGRES_PASSWORD=1234-d postgres > container_id
docker exec -it `cat container_id` psql -U postgres
```

Note that Windows uses backslash instead of slash as path separater, but the part after the colon use a slash, since it's a path inside the Linux container.

The container id is stored in a file called 'container_id', to make it easier to later stop the container.

Now you're in PostgreSQL, with raw data already imported to the "events" table, and statistics in the "stats" table. You can do any SQL queries you like, eg:

```
postgres=# \d
                    List of relations
 Schema |           Name           |   Type   |  Owner   
--------+--------------------------+----------+----------
 public | by_device                | table    | postgres
 public | by_device_and_month      | table    | postgres
 public | by_last_seen             | table    | postgres
 public | by_month                 | table    | postgres
 public | by_type                  | table    | postgres
 public | by_type_and_manufacturer | table    | postgres
 public | downtime                 | table    | postgres
 public | downtime_periods         | table    | postgres
 public | events                   | table    | postgres
 public | events_id_seq            | sequence | postgres
 public | range                    | table    | postgres
(11 rows)

postgres=# select type,ag,manufacturer,disconnects,up_percentage from by_device order by up_percentage ASC;
         type          |            ag            | manufacturer | disconnects | up_percentage 
-----------------------+--------------------------+--------------+-------------+---------------
 RSMP traffic light    | 2604                     | DNQ          |        1846 |         11.34
 RSMP traffic light    | 3112                     | DNQ          |        2385 |         11.58
 RSMP traffic light    | 2613                     | DNQ          |        5042 |         28.30
 RSMP traffic light    | 2907                     | DNQ          |       16167 |         41.48
 Radar                 | 1207                     | SMI          |          95 |         43.15
 RSMP traffic light    | 1105                     | DNQ          |          45 |         44.81
 RSMP VMS              | 0606                     | ITT          |          82 |         46.00
```

Note that when you run psql, the data import and analysis might still be ongoing. You can check the modification date of the exported csv files to see when the export is done.

If you want to output data to CSV, look at analyse.sql to see how it's done.

### Exiting
When done, you might want to exit sql and exit the container:

```
postgres=# \q
root@71364c7e3116 :/# exit
```

The container is still running. You can stop if with: 

Mac/Linux:
```
$ docker stop `cat container_id`; rm container_id;
```

## Notes

### Docker files
The tool uses a docker container to run PostgreSQL and perform the analysis. 
The folder data/ is mounted as a volume to read the input and save the output.
The volume is mounted at /docker-entrypoint-initdb.d. Any .sql files in the folder is run be default by the PostgresSQL iamge after the database has been initialied. So the file data/analyze.sql will be run when the container is started.
The file data/analys.sql contains the SQL commands to import the csv file, run the analysis and store the result in a csv file.

### Uptime computation
The Postgres lag() function is used to compute the duration between consecutive pairs of disconnect-connect pairs.
Disconnects are expected to be followed by a connect. If several disconnects occur without a connect in between, then only the last disconnect-connect duration will be used.

All statistics is aggregated by month. Downtime periods covering more than one month are split correctly into the relevant months.


