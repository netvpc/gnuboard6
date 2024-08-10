#!/bin/bash

chown -R g6:g6 /g6

## TODO: make dynamic .env file
exec gosu g6 "$@"