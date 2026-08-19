# Repo-root entry point. Every target is forwarded to the platform Makefile
# for the host OS, so `make build` from here matches `cd macos && make build`.

ROOT_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
  PLATFORM_DIR := macos
else ifeq ($(UNAME_S),Linux)
  PLATFORM_DIR := fcitx5
else
  $(error Unsupported host OS "$(UNAME_S)"; run make inside a platform directory)
endif

# Goals answered here rather than forwarded — repo-wide work that belongs to no
# single platform. List the name here and give it a rule at the bottom.
LOCAL_GOALS :=

# Everything else goes to the platform Makefile in a single sub-make, so shared
# prerequisites such as prepare run once and the platform Makefile keeps
# deciding their order.
ifeq (,$(MAKECMDGOALS))
  DELEGATED_GOALS := default
  FORWARDED_GOALS :=
else
  DELEGATED_GOALS := $(filter-out $(LOCAL_GOALS),$(MAKECMDGOALS))
  FORWARDED_GOALS := $(DELEGATED_GOALS)
endif

# The first goal carries the recipe and the rest hang off it, so a failure is
# reported against a goal the user typed. Clearing MAKELEVEL keeps the sub-make
# diagnostics free of the make[1] prefix.
FIRST_GOAL := $(firstword $(DELEGATED_GOALS))
OTHER_GOALS := $(wordlist 2,$(words $(DELEGATED_GOALS)),$(DELEGATED_GOALS))

.NOTPARALLEL:

# Skipped when every goal is local, where there is nothing to forward and an
# empty target name would be a parse error.
ifneq (,$(DELEGATED_GOALS))
.PHONY: $(DELEGATED_GOALS)

$(FIRST_GOAL):
	@MAKELEVEL= $(MAKE) -C $(ROOT_DIR)$(PLATFORM_DIR) $(FORWARDED_GOALS)

$(OTHER_GOALS): $(FIRST_GOAL)
	@:
endif
