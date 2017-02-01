#!/bin/bash

if [ ! -d /sys/class/gpio/gpio25 ]; then
        echo 25 > /sys/class/gpio/export
        echo out > /sys/class/gpio/gpio25/direction
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd $DIR

. /etc/doorbot-env

ruby logcards.rb
