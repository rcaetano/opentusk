.PHONY: lint

# Run shellcheck on all shell scripts
lint:
	@echo "Running shellcheck..."
	@shellcheck -x opentusk scripts/*.sh
	@echo "shellcheck passed."
