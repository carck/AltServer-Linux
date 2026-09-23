cur_dir := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
MAIN_DIR := $(dir $(abspath $(cur_dir)))
MAIN_DIR := $(MAIN_DIR:/=)

BUILD_DIR := $(CURDIR)

UPSTREAM_DIR := $(MAIN_DIR)/upstream_repo

LIB_DIR := $(MAIN_DIR)/libraries

DEBUG ?= 0

CFLAGS ?=

ifeq ($(DEBUG),1)
CFLAGS += -O0 -g -DDEBUG
else
CFLAGS += -O2 -DNDEBUG
endif