TRAIL := 白姑大山

# Enforce positional trail selection (no `TRAIL=...` overrides).
ifeq ($(origin TRAIL),command line)
  $(error Do not pass TRAIL=...; use positional form: `make <target> <trailDir>` (e.g. `make clean 白姑大山`))
endif

# Allow: `make <target> <trailDir>` for targets that use TRAIL.
# In GNU make, extra words are treated as goals, so we capture the 2nd word
# as TRAIL and add a no-op rule for it.
ifneq (,$(filter docker/generate clean generate,$(MAKECMDGOALS)))
  TRAIL_ARG := $(word 2,$(MAKECMDGOALS))
  ifneq (,$(TRAIL_ARG))
    TRAIL := $(TRAIL_ARG)
    $(eval $(TRAIL_ARG):;@:)
  endif
  # Some trails have multiple lines (e.g. SM400 main + sub-lines),
  # so we also capture any remaining positional args as LINE_CODES.
  # Example: `make docker/generate 白姑大山 SM400`
  LINE_CODES := $(wordlist 3,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))
  ifneq (,$(LINE_CODES))
    $(foreach code,$(LINE_CODES),$(eval $(code):;@:) )
  endif
endif

# Safety: ensure TRAIL resolves under this repo root (CURDIR).
# Prevents accidental deletion (e.g. TRAIL=.., TRAIL=/, or empty) in `clean`,
# and ensures generators only operate on repo-contained inputs.
CURDIR_ABS := $(abspath $(CURDIR))
TRAIL_ABS := $(abspath $(TRAIL))
ifneq (,$(filter clean generate docker/generate,$(MAKECMDGOALS)))
  ifeq ($(filter $(CURDIR_ABS)/%,$(TRAIL_ABS)),)
    $(error TRAIL must be under $(CURDIR_ABS). Got TRAIL='$(TRAIL)' (resolved to '$(TRAIL_ABS)'))
  endif
endif

clean:
	rm -rf $(TRAIL)/output

generate:
	@if [ -z "$(LINE_CODES)" ]; then \
		echo "Usage: make generate <trailDir> <LINE_CODE...> (example: make generate 雪山西稜 SM300)"; \
		exit 1; \
	fi
	@for code in $(LINE_CODES); do \
		ruby generate.rb $(TRAIL)/$${code}_milestone.yaml; \
		ruby generate.rb $(TRAIL)/$${code}_blank.yaml; \
	done

docker/generate: docker/build
	@if [ -z "$(LINE_CODES)" ]; then \
		echo "Usage: make docker/generate <trailDir> <LINE_CODE...> (example: make docker/generate 雪山西稜 SM300)"; \
		exit 1; \
	fi
	@for code in $(LINE_CODES); do \
		docker run -it --rm \
			--user builder \
			-v $(CURDIR):/home/builder/workdir \
			-e TERM=$$TERM \
			rudychung/tsg \
			$(TRAIL)/$${code}_milestone.yaml; \
		docker run -it --rm \
			--user builder \
			-v $(CURDIR):/home/builder/workdir \
			-e TERM=$$TERM \
			rudychung/tsg \
			$(TRAIL)/$${code}_blank.yaml; \
	done

docker/build:
	docker build -t rudychung/tsg docker

# The positional args (trail dir + line codes) are goals with no-op rules, and
# most of them name an existing directory. Mark them phony so make runs the
# no-op recipe instead of reporting "is up to date".
.PHONY: clean generate docker/build docker/generate $(TRAIL_ARG) $(LINE_CODES)
