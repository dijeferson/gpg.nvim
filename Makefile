.PHONY: test lint format format-check

# Run the test suite headlessly with plenary.
test:
	nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"

# Lint with selene.
lint:
	selene lua/ tests/

# Format in place with stylua.
format:
	stylua lua/ tests/

# Check formatting without modifying files (used by CI).
format-check:
	stylua --check lua/ tests/
