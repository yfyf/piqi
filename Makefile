ifeq ($(MAKECMDGOALS),distclean)
-include Makefile.config
-include $(PIQI_ROOT)/make/Makefile.dirs
else
include Makefile.config
include $(PIQI_ROOT)/make/Makefile.dirs
endif


DIRS = piqilib piqi-tools


.PHONY: deps build-dir install distclean \
	ocaml ocaml-install ocaml-uninstall ocaml-clean \
	doc piqi


# export installation and search path for OCaml dependencies
ifeq ($(MAKECMDGOALS),deps)
export OCAMLFIND_DESTDIR = $(PIQI_BUILD)/lib/ocaml
endif


# export installation path for third-party deps and Piqi OCaml libraries
ifneq ($(findstring ocaml-,$(MAKECMDGOALS)),)
ifneq ($(PIQI_OCAML_DESTDIR),)
export OCAMLFIND_DESTDIR = $(PIQI_OCAML_DESTDIR)
endif
endif


pre_target:: build-dir


deps: build-dir
	$(MAKE) -C deps
	$(MAKE) -C deps install


build-dir:
	mkdir -p build/lib/ocaml
	cd build/lib/ocaml && test -L piqi || ln -sf ../../../piqilib piqi
	cd build/lib/ocaml && test -L piqirun || ln -sf ../../../piqirun-ocaml piqirun


doc:
	$(MAKE) -C doc


install:
	-install -d $(DESTDIR)$(PIQI_PREFIX)/bin
	install piqi-tools/piqi $(DESTDIR)$(PIQI_PREFIX)/bin
	-install -d $(DESTDIR)$(PIQI_PREFIX)/share/man/man1
	install -m 644 doc/piqi.1 $(DESTDIR)$(PIQI_PREFIX)/share/man/man1


# re-generate _piqi.ml from .piqi and copy the latest version of piqilib.ml  --
# called manually as "make piqi" when there were changes in the .piqi files or
# to take advantage of new versions of piqic-ocaml and the piqirun.pb runtime
# library
piqi:
	$(MAKE) -C piqilib piqi
	$(MAKE) -C piqi-tools piqi


ocaml:
	$(MAKE) -C piqirun-ocaml
	$(MAKE) -C piqic-ocaml


ocaml-clean:
	$(MAKE) -C piqirun-ocaml clean
	$(MAKE) -C piqic-ocaml clean


ocaml-install: ocaml-uninstall
	test -d $(PIQI_OCAML_DESTDIR) || mkdir -p $(PIQI_OCAML_DESTDIR)
	$(MAKE) -C deps install
	$(MAKE) -C piqilib install
	$(MAKE) -C piqirun-ocaml install
	-install -d $(DESTDIR)$(PIQI_PREFIX)/bin
	install piqic-ocaml/piqic-ocaml $(DESTDIR)$(PIQI_PREFIX)/bin


ocaml-uninstall:
	$(MAKE) -C deps uninstall
	$(MAKE) -C piqilib uninstall
	$(MAKE) -C piqirun-ocaml uninstall
	rm -f $(DESTDIR)$(PIQI_PREFIX)/bin/piqic-ocaml


clean:: ocaml-clean
	$(MAKE) -C deps clean
	$(MAKE) -C tests clean


distclean:
	if [ -f Makefile.config ]; then \
		$(MAKE) clean; \
		rm -rf $(PIQI_BUILD); \
		rm Makefile.config; \
	fi

