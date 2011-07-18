all: clean build

clean:
	rm -rf ./ebin/*

build:
	erlc -I include -o ebin src/erlfaye_api.erl
	erlc -I include -o ebin src/erlfaye_cluster.erl
	erlc -I include -o ebin src/erlfaye_request.erl
	erlc -I include -o ebin src/erlfaye_websockets_api.erl
	erlc -I include -o ebin src/gen_server_cluster.erl
