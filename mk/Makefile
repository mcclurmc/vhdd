ifdef B_BASE
include $(B_BASE)/common.mk
include $(B_BASE)/rpmbuild.mk
REPO = $(call hg_loc,vhdd)
else
REPO ?= $(CURDIR)
%/.dirstamp:
	@mkdir -p $*
	@touch $@
endif

RPM_BINDIR=$(RPM_RPMSDIR)/$(DOMAIN0_ARCH_OPTIMIZED)

.PHONY: build
build: srpm $(MY_SOURCES)/MANIFEST
	$(RPMBUILD) --target $(DOMAIN0_ARCH_OPTIMIZED) -bb $(RPM_SPECSDIR)/vhdd.spec
	mkdir -p $(MY_MAIN_PACKAGES)
	cp $(RPM_RPMSDIR)/$(DOMAIN0_ARCH_OPTIMIZED)/vhdd-*.rpm $(MY_MAIN_PACKAGES)

.PHONY: srpm
srpm:
	mkdir -p $(RPM_SRPMSDIR) $(RPM_SPECSDIR) $(RPM_SOURCESDIR) $(RPM_RPMSDIR)
	hg archive -p vhdd-0 -t tbz2 $(RPM_SOURCESDIR)/vhdd-0.tar.bz2
	install -o root -g root ../vhdd.spec $(RPM_SPECSDIR)
	$(RPMBUILD) --target $(DOMAIN0_ARCH_OPTIMIZED) -bs $(RPM_SPECSDIR)/vhdd.spec

$(MY_SOURCES)/MANIFEST: $(MY_SOURCES_DIRSTAMP)
	rm -f $@
	@for srpm in "$(/bin/ls -1 ${MY_OUTPUT_DIR}/SRPMS)"; do \
		path=$(MY_OUTPUT_DIR)/SRPMS/${srpm}; \
		echo "$(${RPM} --qf "%{name}" -qp ${path}) $(${RPM} --qf "%{License}" -qp ${path}) ${path}" >>$@; \
	done

.PHONY: clean
	rm -f *.rpm

	
