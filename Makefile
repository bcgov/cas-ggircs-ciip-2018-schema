PERL=perl
RSYNC=rsync
PERL_VERSION=${shell ${PERL} -e 'print substr($$^V, 1)'}
PERL_MIN_VERSION=5.10
CPAN=cpan
CPANM=cpanm
SQITCH=sqitch
SQITCH_VERSION=${word 3,${shell ${SQITCH} --version}}
SQITCH_MIN_VERSION=0.97
GREP=grep
GIT=git
GIT_BRANCH=${shell ${GIT} rev-parse --abbrev-ref HEAD}
# openshift doesn't like slashes
GIT_BRANCH_NORM=${subst /,-,${GIT_BRANCH}}
AWK=awk
PSQL=psql -h localhost
# "psql --version" prints "psql (PostgreSQL) XX.XX"
PSQL_VERSION=${word 3,${shell ${PSQL} --version}}
PG_SERVER_VERSION=${strip ${shell ${PSQL} -tc 'show server_version;' || echo error}}
PG_MIN_VERSION=9.1
PG_ROLE=${shell whoami}
OC=oc
OC_PROJECT= # overridden as needed
OC_DEV_PROJECT=wksv3k-dev
OC_TEST_PROJECT=wksv3k-test
OC_PROD_PROJECT=wksv3k-prod
OC_TOOLS_PROJECT=wksv3k-tools
OC_REGISTRY=docker-registry.default.svc:5000

define check_file_in_path
	${if ${shell which ${word 1,${1}}},
		${info ✓ Found ${word 1,${1}}},
		${error ✖ No ${word 1,${1}} in path.}
	}
endef

define check_min_version_num
	${if ${shell printf '%s\n%s\n' "${3}" "${2}" | sort -CV || echo error},
		${error ✖ ${word 1,${1}} version needs to be at least ${3}.},
		${info ✓ ${word 1,${1}} version is at least ${3}.}
	}
endef

.PHONY: verify_installed
verify_installed:
	$(call check_file_in_path,${PERL})
	$(call check_min_version_num,${PERL},${PERL_VERSION},${PERL_MIN_VERSION})

	$(call check_file_in_path,${CPAN})
	$(call check_file_in_path,${GIT})
	$(call check_file_in_path,${RSYNC})

	$(call check_file_in_path,${PSQL})
	$(call check_min_version_num,${PSQL},${PSQL_VERSION},${PG_MIN_VERSION})
	@@echo ✓ External dependencies are installed

.PHONY: verify_pg_server
verify_pg_server:
ifeq (error,${PG_SERVER_VERSION})
	${error Error while connecting to postgres server}
else
	${info postgres is online}
endif

ifneq (${PSQL_VERSION}, ${PG_SERVER_VERSION})
	${error psql version (${PSQL_VERSION}) does not match the server version (${PG_SERVER_VERSION}) }
else
	${info psql and server versions match}
endif

ifeq (0,${shell ${PSQL} -qAtc "select count(*) from pg_user where usename='${PG_ROLE}' and usesuper=true"})
	${error A postgres role with the name "${PG_ROLE}" must exist and have the SUPERUSER privilege.}
else
	${info postgres role "${PG_ROLE}" has appropriate privileges}
endif

	@@echo ✓ PostgreSQL server is ready

.PHONY: verify
verify: verify_installed verify_pg_server

.PHONY: verify_ready
verify_ready:
	# ensure postgres is online
	@@${PSQL} -tc 'show server_version;' | ${AWK} '{print $$NF}';

.PHONY: verify
verify: verify_installed verify_ready

.PHONY: install_cpanm
install_cpanm:
ifeq (${shell which ${CPANM}},)
	# install cpanm
	@@${CPAN} App:cpanminus
endif

.PHONY: install_cpandeps
install_cpandeps:
	# install sqitch
	${CPANM} -n https://github.com/matthieu-foucault/sqitch/releases/download/v1.0.1.TRIAL/App-Sqitch-v1.0.1-TRIAL.tar.gz
	# install Perl dependencies from cpanfile
	${CPANM} --installdeps .

.PHONY: postinstall_check
postinstall_check:
	@@printf '%s\n%s\n' "${SQITCH_MIN_VERSION}" "${SQITCH_VERSION}" | sort -CV ||\
 	(echo "FATAL: ${SQITCH} version should be at least ${SQITCH_MIN_VERSION}. Make sure the ${SQITCH} executable installed by cpanminus is available has the highest priority in the PATH" && exit 1);

.PHONY: install
install: install_cpanm install_cpandeps postinstall_check

define switch_project
	@@echo ✓ logged in as: $(shell ${OC} whoami)
	@@${OC} project ${OC_PROJECT} >/dev/null
	@@echo ✓ switched project to: ${OC_PROJECT}
endef

define oc_process
	@@${OC} process -f openshift/${1}.yml ${2} | ${OC} apply --wait=true --overwrite=true -f-
endef

define oc_promote
	@@$(OC) tag $(OC_TOOLS_PROJECT)/$(1):$(2) $(1)-mirror:$(2) --reference-policy=local
endef

define build
	@@echo Add all image streams and build in the tools project...
	$(call oc_process,imagestream/cas-ggircs-perl,)
	$(call oc_process,imagestream/cas-ggircs-python,)
	$(call oc_process,imagestream/cas-ciip-extract,)
	$(call oc_process,buildconfig/cas-ciip-extract,GIT_BRANCH=${GIT_BRANCH} GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
endef

define deploy
	$(call oc_process,imagestream/cas-ciip-extract-mirror)
	$(call oc_promote,cas-ciip-extract,${GIT_BRANCH_NORM})
	$(call oc_process,persistentvolumeclaim/cas-ciip-data,)
	$(call oc_process,deploymentconfig/cas-ciip-extract,GIT_BRANCH_NORM=${GIT_BRANCH_NORM})
endef

.PHONY: deploy_tools
deploy_tools: OC_PROJECT=${OC_TOOLS_PROJECT}
deploy_tools:
	$(call switch_project)
	$(call build)

.PHONY: deploy_test
deploy_test_ciip: OC_PROJECT=${OC_TEST_PROJECT}
deploy_test_ciip: deploy_tools
	$(call switch_project)
	$(call deploy_ciip)

.PHONY: deploy_dev
deploy_dev_ciip: OC_PROJECT=${OC_DEV_PROJECT}
deploy_dev_ciip: deploy_tools
	$(call switch_project)
	$(call deploy_ciip)
