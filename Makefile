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
	ruby generate.rb $(TRAIL)/milestone.yaml
	ruby generate.rb $(TRAIL)/blank.yaml

docker/generate: docker/build
	docker run -it --rm \
		--user builder \
		-v $(CURDIR):/home/builder/workdir \
		-e TERM=$$TERM \
		rudychung/tsg \
		$(TRAIL)/milestone.yaml
	docker run -it --rm \
		--user builder \
		-v $(CURDIR):/home/builder/workdir \
		-e TERM=$$TERM \
		rudychung/tsg \
		$(TRAIL)/blank.yaml

docker/build:
	docker build -t rudychung/tsg docker

.PHONY: clean generate docker/build docker/generate
