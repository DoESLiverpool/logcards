#!/bin/bash

# Get a temporary folder to store our working files into
TMP_VISITS_FOLDER=`mktemp --tmpdir -d visitor_stats.XXXX`

# Files we'll hold the different doorbots' visits.log in
DB1_VISITS=$TMP_VISITS_FOLDER/db1_visits.log
DB2_VISITS=$TMP_VISITS_FOLDER/db2_visits.log
DB3_VISITS=$TMP_VISITS_FOLDER/db3_visits.log
COMBINED_VISITS=$TMP_VISITS_FOLDER/combined_visits.log
DAILY_VISITS=$TMP_VISITS_FOLDER/daily_visits.log
DAILY_COUNTS=$TMP_VISITS_FOLDER/daily_counts.log
MONTHLY_COUNTS=$TMP_VISITS_FOLDER/monthly_counts.log
ANNUAL_COUNTS=$TMP_VISITS_FOLDER/annual_counts.log

# Get the visits files
# Assumes you have doorbot[1-3] set up in your ssh aliases
echo "Getting visits from doorbot1"
scp 'doorbot1:/home/pi/logcards/visits.log' $DB1_VISITS
echo "Getting visits from doorbot2"
scp 'doorbot2:/home/pi/logcards/visits.log' $DB2_VISITS
echo "Getting visits from doorbot3"
scp 'doorbot3:/home/pi/logcards/visits.log' $DB3_VISITS

# Get the name and date from each visit, and combine all three into one file
cut -f 3,4 --output-delimiter=' ' $DB1_VISITS | cut -d ' ' -f 1,4-8 > $COMBINED_VISITS
cut -f 3,4 --output-delimiter=' ' $DB2_VISITS | cut -d ' ' -f 1,4-8 >> $COMBINED_VISITS
cut -f 3,4 --output-delimiter=' ' $DB3_VISITS | cut -d ' ' -f 1,4-8 >> $COMBINED_VISITS

# Filter them down to one visit per person per day
sort $COMBINED_VISITS | uniq > $DAILY_VISITS

# Work out the visitor counts 
cut -d ' ' -f 1 $DAILY_VISITS | uniq -c > $DAILY_COUNTS
cut -d ' ' -f 1 $DAILY_VISITS | cut -d '-' -f 1,2 | uniq -c > $MONTHLY_COUNTS
cut -d ' ' -f 1 $DAILY_VISITS | cut -d '-' -f 1 | uniq -c > $ANNUAL_COUNTS

echo "We've had `cat $DAILY_VISITS | wc -l` since records began"
echo
echo "Working files are in $TMP_VISITS_FOLDER"
echo "You should copy them somewhere safe if you want to keep them"
