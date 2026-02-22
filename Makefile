.PHONY: test lint test-all

# Run shellcheck on all shell scripts
lint:
	@echo "Running shellcheck..."
	@shellcheck -x mustangclaw scripts/*.sh
	@echo "shellcheck passed."

# Run bats tests
test:
	@echo "Running bats tests..."
	@bats tests/
	@echo "All tests passed."

# Run both lint and tests
test-all: lint test
