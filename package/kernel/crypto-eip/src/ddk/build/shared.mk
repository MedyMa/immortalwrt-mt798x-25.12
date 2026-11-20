# SPDX-License-Identifier: GPL-2.0-or-later
# Each DDK module compiles shared sources with its own configuration headers.
$(obj)/shared/%.o: $(src)/../../%.c FORCE
	$(call if_changed_rule,cc_o_c)
	$(call cmd,force_checksrc)
