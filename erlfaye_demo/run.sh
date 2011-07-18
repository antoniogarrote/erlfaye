#!/bin/bash

cd ./_build/development/apps/erlfaye_demo-1.0.0 && erl -pa `pwd`/ebin -boot start_sasl -config ./config/sys.config -s erlfaye_demo_app demo -sname erlfaye_demo
