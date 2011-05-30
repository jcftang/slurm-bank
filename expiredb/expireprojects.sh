#!/bin/sh

recsel -C -R project -t project -e "enddate << '`date -I`'" projects.rec
