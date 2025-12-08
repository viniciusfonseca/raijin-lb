build:
	zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

debug:
	zig build -Doptimize=Debug

run-debug:
	TCP_UPSTREAMS=127.0.0.1:3001,127.0.0.1:3002 zig build run -Doptimize=Debug

run-docker:
	docker compose down
	docker compose up

start-upstreams:
	docker compose down
	docker compose up -d upstream01 upstream02

clean:
	du -sh .zig-cache
	rm -rf .zig-cache
	du -sh zig-out/bin/raijin-lb
	rm -rf zig-out