TRAIL := 白姑大山

# Enforce positional trail selection (no `TRAIL=...` overrides).
ifeq ($(origin TRAIL),command line)
  $(error Do not pass TRAIL=...; use positional form: `make <target> <trailDir>` (e.g. `make clean 白姑大山`))
endif

# Targets that take positional arguments, and every real target a positional
# argument must not be confused with.
TRAIL_TARGETS := clean generate docker/generate
REAL_TARGETS := help clean generate docker/build docker/generate

# `clean` is the first target in this file and was therefore make's default
# goal, so a bare `make` silently deleted 白姑大山/output — a whole batch of
# print-ready PDFs, gone to a typo. Print usage instead.
.DEFAULT_GOAL := help

# Allow: `make <target> <trailDir> [<LINE_CODE>...]` for targets that use TRAIL.
# In GNU make, extra words are treated as goals, so we capture the 2nd word as
# TRAIL, any remaining words as LINE_CODES (a trail may have several lines, and
# each is generated in turn), and add no-op rules for them.
ifneq (,$(filter $(TRAIL_TARGETS),$(MAKECMDGOALS)))
  POSITIONAL := $(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS))

  # A positional argument that happens to name a real target is not harmless:
  # that target's recipe overrides the no-op rule below and make runs it for
  # real. `make generate 白姑大山 clean` would look for clean_milestone.yaml and
  # then delete 白姑大山/output. Reject the collision instead.
  RESERVED_USED := $(filter $(REAL_TARGETS),$(POSITIONAL))
  ifneq (,$(RESERVED_USED))
    $(error '$(RESERVED_USED)' names a make target and cannot be used as a trail directory or line code; run the targets one at a time)
  endif

  TRAIL_ARG := $(word 1,$(POSITIONAL))
  LINE_CODES := $(wordlist 2,$(words $(POSITIONAL)),$(POSITIONAL))
  ifneq (,$(TRAIL_ARG))
    TRAIL := $(TRAIL_ARG)
  endif
  $(foreach arg,$(POSITIONAL),$(eval $(arg):;@:))

  # Require line codes at parse time rather than inside the recipes, so that
  # `make docker/generate <trailDir>` fails immediately instead of after
  # docker/build has spent minutes building the image.
  GENERATE_GOALS := $(filter generate docker/generate,$(MAKECMDGOALS))
  ifneq (,$(GENERATE_GOALS))
    ifeq (,$(LINE_CODES))
      $(error Usage: make $(GENERATE_GOALS) <trailDir> <LINE_CODE...> (example: make generate 雪山西稜 SM300))
    endif
  endif
endif

# Safety: ensure TRAIL resolves under this repo root (CURDIR).
# Prevents accidental deletion (e.g. TRAIL=.., TRAIL=/, or empty) in `clean`,
# and ensures generators only operate on repo-contained inputs.
CURDIR_ABS := $(abspath $(CURDIR))
TRAIL_ABS := $(abspath $(TRAIL))
ifneq (,$(filter $(TRAIL_TARGETS),$(MAKECMDGOALS)))
  ifeq ($(filter $(CURDIR_ABS)/%,$(TRAIL_ABS)),)
    $(error TRAIL must be under $(CURDIR_ABS). Got TRAIL='$(TRAIL)' (resolved to '$(TRAIL_ABS)'))
  endif
endif

help:
	@echo "Usage: make <target> <trailDir> [<LINE_CODE>...]"
	@echo ""
	@echo "  generate <trailDir> <LINE_CODE...>         generate PDFs locally (Ruby)"
	@echo "  docker/generate <trailDir> <LINE_CODE...>  the same, inside the docker image"
	@echo "  docker/build                               build the docker image"
	@echo "  clean <trailDir>                           remove <trailDir>/output"
	@echo ""
	@echo "Examples:"
	@echo "  make generate 白姑大山 SM400"
	@echo "  make clean 白姑大山"
	@echo ""
	@echo "Several lines of one trail can be generated in a single run:"
	@echo "  make generate <trailDir> <CODE_A> <CODE_B>"

clean:
	rm -rf $(TRAIL)/output

# `|| exit 1` on every run: the loop body is one shell command list, so without
# it a failed line would be followed by the remaining ones and the recipe would
# still exit 0 — handing back a silently incomplete batch to send to the printer.
generate:
	@for code in $(LINE_CODES); do \
		ruby generate.rb $(TRAIL)/$${code}_milestone.yaml || exit 1; \
		ruby generate.rb $(TRAIL)/$${code}_blank.yaml || exit 1; \
	done

docker/generate: docker/build
	@for code in $(LINE_CODES); do \
		docker run -it --rm \
			--user builder \
			-v $(CURDIR):/home/builder/workdir \
			-e TERM=$$TERM \
			rudychung/tsg \
			$(TRAIL)/$${code}_milestone.yaml || exit 1; \
		docker run -it --rm \
			--user builder \
			-v $(CURDIR):/home/builder/workdir \
			-e TERM=$$TERM \
			rudychung/tsg \
			$(TRAIL)/$${code}_blank.yaml || exit 1; \
	done

docker/build:
	docker build -t rudychung/tsg docker

# The positional args (trail dir + line codes) are goals with no-op rules, and
# most of them name an existing directory. Mark them phony so make runs the
# no-op recipe instead of reporting "is up to date".
.PHONY: $(REAL_TARGETS) $(POSITIONAL)
