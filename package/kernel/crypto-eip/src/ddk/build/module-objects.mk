# SPDX-License-Identifier: GPL-2.0-or-later
# Each DDK module selects different cs_* headers. Give each module its own
# object paths so parallel builds cannot overwrite another module's objects.
eip_ddk_modules := $(patsubst %.o,%,$(filter %.o,$(obj-m) $(obj-y)))
$(foreach eip_ddk_module,$(eip_ddk_modules),\
	$(eval $(eip_ddk_module)-y := $(patsubst ../../%,%,$($(eip_ddk_module)-y))))

$(obj)/%.o: $(src)/../../%.c FORCE
	@mkdir -p $(dir $@)
	$(call if_changed_rule,cc_o_c)
	$(call cmd,force_checksrc)
