DEVSTACK_WORKSPACE ?= ..
THEMES_DIR = $(DEVSTACK_WORKSPACE)/src/themes
CUSTOMER_THEME_DIR = $(THEMES_DIR)/edx-theme-codebase/customer_specific
AMC_DIR = $(DEVSTACK_WORKSPACE)/amc

UNAME_S := $(shell uname -s)
LINUX_CMD ?= true
MACOSX_CMD ?= true

tahoe.os.exec:  ## Executes operating system-specific commands
ifeq ($(UNAME_S),Linux)
	bash -c '$(LINUX_CMD)'
endif
ifeq ($(UNAME_S),Darwin)
	bash -c '$(MACOSX_CMD)'
endif

tahoe.exec.single:  ## Execute a command inside a devstack docker container
	docker exec -t edx.devstack.$(SERVICE)  \
		bash -c 'source /edx/app/edxapp/edxapp_env && cd /edx/app/edxapp/edx-platform/ && $(COMMAND)'

tahoe.exec.edxapp:   ## Execute a command in both LMS and Studio (edxapp containers)
	make COMMAND='$(COMMAND)' SERVICE=lms tahoe.exec.single
	make COMMAND='$(COMMAND)' SERVICE=studio tahoe.exec.single

tahoe.install-pip.edxapp:  ## Install a pip package in both of LMS and Studio
	make COMMAND='pip install $(PACKAGE)' SERVICE=lms tahoe.exec.single
	make COMMAND='pip install $(PACKAGE)' SERVICE=studio tahoe.exec.single

tahoe.chown.dir:  # Fix permissions for a single directory
	find $(DIRECTORY) \! -user $(USER) -print -exec sudo chown -R $(USER) {} \;

tahoe.chown:  ## Fix an annoying docker permission issue in both `edx-platform` and `src`
	make DIRECTORY='$(DEVSTACK_WORKSPACE)/edx-platform/' tahoe.chown.dir
	make DIRECTORY='$(DEVSTACK_WORKSPACE)/src/' tahoe.chown.dir

tahoe.theme.compile:  ## Compile the static assets of the theme
	make COMMAND='make requirements' tahoe.exec.edxapp
	make lms-static
	make studio-static

tahoe.theme.reset:  ## Removes and re-clone the theme with Tahoe branches
	make tahoe.chown
	rm -rf $(THEMES_DIR)

	git clone git@github.com:appsembler/edx-theme-codebase.git $(THEMES_DIR)/edx-theme-codebase
	cd $(THEMES_DIR)/edx-theme-codebase && git checkout hawthorn/master

	git clone git@github.com:appsembler/edx-theme-customers.git $(CUSTOMER_THEME_DIR)
	cd $(CUSTOMER_THEME_DIR) && git checkout hawthorn/amc

	make tahoe.chown

tahoe.init.provision-script:  ## Execute the `provision-tahoe.py` script in both of LMS and Studio
	cat $(DEVSTACK_WORKSPACE)/devstack/provision-tahoe.py > $(DEVSTACK_WORKSPACE)/src/provision-tahoe.py
	make COMMAND='python /edx/src/provision-tahoe.py' tahoe.exec.edxapp
	rm $(DEVSTACK_WORKSPACE)/src/provision-tahoe.py

tahoe.init:  ## Make the devstack more Tahoe'ish
	make tahoe.init.provision-script
	# TODO: Install within the Tahoe Open edX images
	make PACKAGE='git+https://github.com/appsembler/edx-organizations.git@0.4.10-appsembler3' tahoe.install-pip.edxapp
	make tahoe.restart || true

tahoe.up:  ## Run the devstack with proper Tahoe settings, use instead of `$ make dev.up`
	make tahoe.chown
	make dev.up
	@sleep 1
	make tahoe.init
	test -d $(CUSTOMER_THEME_DIR) || (make tahoe.theme.reset && tahoe.theme.compile)
	test -d $(AMC_DIR) || make amc.reset
	test -f $(AMC_DIR)/amc/.env || make amc.env-file
	make tahoe.chown

tahoe.reset.light:  ## Resets the Tahoe settings including a fresh theme copy and new environment files.
	make down
	sudo rm -rf $(DEVSTACK_WORKSPACE)/src/edxapp-envs
	make amc.reset
	make tahoe.theme.reset
	@sleep 1
	make tahoe.up
	make tahoe.theme.compile

tahoe.reset.full:  ## Does a full reset for everything known to devstack. Will loose all git and database changes.
	make dev.reset
	make tahoe.reset.light

tahoe.restart:  ## Restarts both of LMS and Studio python processes while keeping the same container
	make lms-restart
	make studio-restart

tahoe.amc.oauth-client:  ## Creates the AMC OAuth client in the LMS
	# Keep in sync with `amc.env.initial` file
	make COMMAND='python manage.py lms create_oauth2_client http://localhost:9000/     http://localhost:9000/oauth2/access_token/ confidential --client_name AMC --client_id 6f2b93d5c02560c3f93f     --client_secret 2c6c9ac52dd19d7255dd569fb7eedbe0ebdab2db --trusted --settings=devstack_docker' SERVICE='lms' tahoe.exec.single

amc.env-file:  ## Removes and uses a fresh copy of the AMC env file
	rm -f $(AMC_DIR)/amc/.env
	cp $(DEVSTACK_WORKSPACE)/devstack/amc.env.initial $(AMC_DIR)/amc/.env

amc.reset:  ## Removes and re-initialize AMC
	rm -rf $(AMC_DIR)
	git clone git@github.com:appsembler/amc.git $(AMC_DIR)

	make LINUX_CMD='sudo apt install python3 libjpeg8-dev' tahoe.os.exec
	make MACOSX_CMD='brew install python3 libjpeg zlib' tahoe.os.exec

	cd $(AMC_DIR)/amc/ && virtualenv -p python3 env
	cd $(AMC_DIR)/amc/ && . env/bin/activate && pip install --upgrade pip
	cd $(AMC_DIR)/amc/ && . env/bin/activate && pip install -r ../requirements/local.txt
	cd $(AMC_DIR)/amc/ && . env/bin/activate && pip install mysql-python

	cd $(AMC_DIR)/frontend/ && npm install || true

	make amc.env-file

	make amc.migrate
	make tahoe.amc.oauth-client

amc.start.backend:  ## Starts the AMC Django app
	bash -c 'cd $(AMC_DIR)/amc/ && source env/bin/activate && source .env && python manage.py runserver 0.0.0.0:9000'

amc.migrate:  ## Migrate the AMC database
	bash -c 'cd $(AMC_DIR)/amc/ && source env/bin/activate && source .env && python manage.py migrate'

amc.start.frontend:  ## Starts the AMC Frontend
	bash -c 'cd $(AMC_DIR)/frontend/ && npm start'
