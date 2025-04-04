build:
	zig build-exe main.zig

run: build
	./main

test:
	zig test tree.zig