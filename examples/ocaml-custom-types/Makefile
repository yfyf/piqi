include $(PIQI_ROOT)/make/Makefile.ocaml


RESULT = a.out


SOURCES = \
	$(PIQI_ML_FILES1) \
	piqirun_custom.ml \
	$(PIQI_ML_FILES2) \


PACKS = piqirun.pb num


PIQI_FILES = example.piqi skvl.piqi
PIQI_ML_FILES1 = skvl_piqi.ml
PIQI_ML_FILES2 = example_piqi.ml
PIQI_ML_FILES = $(PIQI_ML_FILES1) $(PIQI_ML_FILES2)


PRE_TARGETS = $(PIQI_ML_FILES)


PIQIC = piqic-ocaml
PIQIC_FLAGS = --pp #--leave-tmp-files


all: native-code #byte-code debug-code


$(PIQI_ML_FILES): $(PIQI_FILES)
	set -e; \
	for i in $^; do \
		$(PIQIC) $(PIQIC_FLAGS) $$i ; \
	done


clean::
	rm -f *.tmp.ml


include $(OCAMLMAKEFILE)
