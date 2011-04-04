include $(PIQI_ROOT)/make/Makefile.ocaml
include $(PIQI_ROOT)/piqilib/Makefile.piqilib


RESULT = piqi

SOURCES += \
	piqi_json_pp.ml \
	\
	piqi_pp_cmd.ml \
	piqi_convert.ml \
	piqi_check.ml \
	piqi_expand.ml \
	piqi_light_cmd.ml \
	piqi_getopt_cmd.ml \
	\
	piqi_to_proto.ml \
	\
	descriptor.ml \
	piqi_of_proto.ml \
	\
	piqi_rpc.ml \
	piqi_tools.ml \
	piqi_server.ml \
	\
	piqi_http.ml \
	piqi_call.ml \
	\
	piqi_run.ml \


PIQI_MODULES = descriptor.piqi piqi-tools.piqi piqi-rpc.piqi

PIQI_ML_SOURCES = $(PIQI_MODULES:%.piqi=%.ml)
PIQI_ML_USOURCES = $(PIQI_MODULES:%.piqi=%.ml)


PRE_TARGETS += \
	$(PIQI_SOURCES) $(PIQI_PIQI) $(PIQI_ML_SOURCES) \
	piqi_tools.ml \
	piqi_rpc.ml
	

PACKS += unix


PIQIC = ../piqic/piqic
# TODO: we don't need to embed piqi in descriptor.ml
PIQIC_FLAGS = -I $(PIQI_ROOT) --embed-piqi


#OCAMLBLDFLAGS = -custom


all: nc


debug: dc top


$(PIQI_ML_SOURCES): %.ml: %.piqi
	$(PIQIC) ocaml $(PIQIC_FLAGS) --pp -o $@ $<

piqi_tools.ml: piqi-tools.ml
	ln -s $< $@

piqi_rpc.ml: piqi-rpc.ml
	ln -s $< $@


clean::


include $(OCAMLMAKEFILE)