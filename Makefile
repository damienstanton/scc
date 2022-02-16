Executables=${TestExecutables} shsh shsh-prof
TestExecutables=$(addprefix test/, scc parallel benchmark-coroutine incremental-parser monoid-subclasses)
IncrementalParserFiles=incremental-parser/Text/ParserCombinators/Incremental.hs \
                       incremental-parser/Control/Applicative/Monoid.hs $(MonoidSubclassFiles)
MonoidSubclassFiles=$(addsuffix .hs, \
	              $(addprefix monoid-subclasses/Data/Monoid/, Cancellative Factorial Null Textual))
MonoidInstanceFiles=$(addsuffix .hs, $(addprefix monoid-subclasses/Data/Monoid/Instances/, \
                      ByteString/UTF8 Concat Measured Positioned Stateful))
ParallelLibraryFiles=$(addprefix monad-parallel/Control/Monad/, Parallel.hs)
CoroutineLibraryFiles=$(IncrementalParserFiles)      \
	                   $(ParallelLibraryFiles)        \
	                   $(addprefix monad-coroutine/Control/Monad/,    \
                                  Coroutine.hs Coroutine/SuspensionFunctors.hs Coroutine/Nested.hs)
SCCCommonFiles=$(CoroutineLibraryFiles) \
                Control/Concurrent/Configuration.hs  \
	      	    $(addprefix Control/Concurrent/SCC/, \
                            Streams.hs Types.hs Coercions.hs Primitives.hs Configurable.hs XML.hs)
AllLibraryFiles=$(SCCCommonFiles) Control/Monad/Coroutine/Enumerator.hs \
                Control/Concurrent/SCC/Combinators.hs \
                Control/Concurrent/SCC/Combinators/Parallel.hs Control/Concurrent/SCC/Combinators/Sequential.hs \
                Control/Concurrent/SCC/Parallel.hs Control/Concurrent/SCC/Sequential.hs
DocumentationFiles=$(SCCCommonFiles) \
                Control/Concurrent/SCC/Combinators/Parallel.hs Control/Concurrent/SCC/Combinators/Sequential.hs \
                Control/Concurrent/SCC/Parallel.hs Control/Concurrent/SCC/Sequential.hs
OptimizingOptions=-O -threaded -fcontext-stack=30 -rtsopts -hidir obj -odir obj $(GeneralOptions)
ProfilingOptions=-prof -auto-all -rtsopts -hidir prof -odir prof $(GeneralOptions)
GeneralOptions=-i.:monoid-subclasses:incremental-parser:monad-parallel:monad-coroutine $(addprefix -package-db , $(wildcard .cabal-sandbox/*-packages.conf.d))

all: $(Executables) doc/index.html

docs: doc/index.html

test/scc: Test/TestSCC.hs $(AllLibraryFiles) | obj test
	ghc --make $< -o $@ $(OptimizingOptions)

test/benchmark-coroutine: monad-coroutine/Test/BenchmarkCoroutine.hs $(CoroutineLibraryFiles) | obj test
	ghc --make $< -o $@ $(OptimizingOptions) -eventlog

test/incremental-parser: incremental-parser/Test/TestIncrementalParser.hs $(IncrementalParserFiles) | obj test
	ghc --make $< -o $@ $(OptimizingOptions) -eventlog

test/monoid-subclasses: monoid-subclasses/Test/TestMonoidSubclasses.hs $(MonoidSubclassFiles) $(MonoidInstanceFiles) | obj test
	ghc --make $< -o $@ $(OptimizingOptions) -eventlog -hide-package checkers -package quickcheck-instances \
        -cpp -D'MIN_VERSION_containers(x,y,z)=1'

test/enumerator: Test/TestEnumerator.hs $(CoroutineLibraryFiles) Control/Monad/Coroutine/Enumerator.hs | obj test
	ghc --make $< -o $@ $(OptimizingOptions) -eventlog

test/iteratee: Test/TestIteratee.hs $(CoroutineLibraryFiles) Control/Monad/Coroutine/Iteratee.hs | obj test
	ghc --make $< -o $@ $(OptimizingOptions) -eventlog

test/parallel: monad-parallel/Test/TestParallel.hs $(ParallelLibraryFiles) | obj test
	ghc --make $< -o $@ $(OptimizingOptions) -eventlog

shsh: Shell.hs $(AllLibraryFiles) | obj
	ghc --make $< -o $@ $(OptimizingOptions)

shsh-prof: Shell.hs $(AllLibraryFiles) | prof
	ghc --make $< -o $@ $(ProfilingOptions)

test/scc-prof: Test/TestSCC.hs $(AllLibraryFiles) | prof test
	ghc --make $< -o $@ $(ProfilingOptions)

doc/index.html: $(DocumentationFiles) | doc
	haddock -hU -o doc --optghc="$(GeneralOptions)" \
	   -i http://www.haskell.org/ghc/docs/latest/html/libraries/base,base.haddock \
	   -i $(lastword $(wildcard ~/.cabal/share/doc/*/transformers-*/html/)),$(lastword $(wildcard ~/.cabal/share/doc/*/transformers-*/html/transformers.haddock)) \
	   -i $(lastword $(wildcard ~/.cabal/share/doc/*/text-*/html/)),$(lastword $(wildcard ~/.cabal/share/doc/*/text-*/html/text.haddock)) \
	   $^

obj prof test doc:
	mkdir -p $@

clean:
	rm -rf obj/* prof/* doc/* dist/* $(Executables)
	rm -f $(foreach SourceFile,$(LibraryFiles),$(SourceFile:%.hs=%.o) $(SourceFile:%.hs=%.hi))
