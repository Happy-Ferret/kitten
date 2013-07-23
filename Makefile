.NOTPARALLEL :

HLINT ?= hlint
CABAL ?= cabal

CABALFLAGS += --enable-tests
MAKEFLAGS += --warn-undefined-variables
.SECONDARY :

BUILDDIR = ./dist/build/Kitten
KITTEN = $(BUILDDIR)/kitten
PRELUDE = $(BUILDDIR)/Prelude.ktn
TESTER = ./test/run.sh
TESTS = $(basename $(notdir $(wildcard test/*.ktn)))
YARN = $(BUILDDIR)/yarn

YARN_HEADERS = $(wildcard interpreter/*.h)
YARN_SOURCES = $(wildcard interpreter/*.cpp)

.PHONY : default
default : build yarn prelude unit test

.PHONY : all
all : deps configure default lint

.PHONY : build
build $(KITTEN) :
	$(CABAL) build

.PHONY : yarn
yarn : $(YARN) $(YARN_HEADERS)

$(YARN) : $(YARN_SOURCES)
	$(CXX) $^ -o $@ -std=c++11 -stdlib=libc++ -Wall -pedantic -g

.PHONY : clean
clean :
	$(CABAL) clean
	rm -f test/*.actual

.PHONY : configure
configure :
	$(CABAL) configure $(CABALFLAGS)

.PHONY : deps
deps :
	$(CABAL) install $(CABALFLAGS) --only-dependencies

.PHONY : prelude
prelude : $(PRELUDE)

$(PRELUDE) : $(KITTEN) Prelude.ktn
	cp Prelude.ktn $(PRELUDE)
	cp Prelude_*.ktn $(BUILDDIR)
	$(KITTEN) --no-implicit-prelude $(PRELUDE)

.PHONY: unit
unit:
	$(CABAL) test

define TESTRULE
test-$1 : $(KITTEN) $(PRELUDE) $(TESTER)
	@$(TESTER) $$(realpath $(KITTEN)) $1
test : test-$1
endef

.PHONY : $(foreach TEST,$(TESTS),test-$(TEST))
$(foreach TEST,$(TESTS),$(eval $(call TESTRULE,$(TEST))))

.PHONY : lint
lint :
	@ $(HLINT) src lib || echo "Can't lint; hlint not on the path."

.PHONY : loc
loc :
	@ find src lib test \
		\( -name '*.hs' -o -name '*.ktn' \) \
		-exec wc -l {} + \
		| sort -n
