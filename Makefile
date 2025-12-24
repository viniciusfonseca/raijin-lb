build:
	zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

small:
	zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl

debug:
	zig build -Doptimize=Debug

run-debug:
	TCP_UPSTREAMS=127.0.0.1:3001,127.0.0.1:3002 zig build run -Doptimize=Debug

setup-docker:
	sudo systemctl start docker
	sudo chmod 666 /var/run/docker.sock

run-docker:
	docker compose down
	docker compose up --build -d

start-upstreams:
	docker compose down
	docker compose up -d upstream01 upstream02

run-load-tests:
	k6 run -e TARGET_LB_URL=http://127.0.0.1:9001 -e VUS=100 test/load-test.js
	k6 run -e TARGET_LB_URL=http://127.0.0.1:9002 -e VUS=100 test/load-test.js

clean:
	du -sh .zig-cache
	rm -rf .zig-cache
	du -sh zig-out/bin/raijin-lb
	rm -rf zig-out