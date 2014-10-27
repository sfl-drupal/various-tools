#!/bin/bash

ECHO=/bin/echo
which cowsay >/dev/null 2>&1 && ECHO="`which cowsay` -W 80" && test -e /usr/share/cowsay/dragon.cow && ECHO="$ECHO -f /usr/share/cowsay/dragon.cow"

MAINTENANCE_MODE=1
ONLINE_MODE=0
DRUPAL_ROOT=${WORKSPACE}/src/
# Change this if needed
if [ -r ~/.drush-deploy.rc ]; then
    source ~/.drush-deploy.rc
else
    DB_USER=testuser
    DB_PASS=testuser
fi

# Deploy code on specified environment with rsync
# Param should be a drush valid alias for the current drupal installation
# cf aliases.drushrc.php
function site_deploy {
    # Put site on maintenance mode
    site_offline 

    $ECHO "Deploying code on $env environment ..."
    drush --yes rsync --exclude=sites/default/files --exclude=.htaccess --delete --verbose @self @$DRUPAL_ENV

    if [ $DRUPAL_ENV != prod ]; then
        if [ "${sqlreplace}" == true ]; then
            $ECHO "Synchronising SQL database from self to $DRUPAL_ENV"
            drush --yes sql-sync --create-db @self @$DRUPAL_ENV
        fi
    fi

    # Run any available database update
    $ECHO "Running available database update(s) on $DRUPAL_ENV environment ..."
    drush --yes @$DRUPAL_ENV updatedb

    # Put site online
    site_online
}

function site_offline {
    $ECHO "Setting $DRUPAL_ENV environment on maintenance mode ..."
    drush --yes @$DRUPAL_ENV vset maintenance_mode $MAINTENANCE_MODE
}

function site_online {
    $ECHO "Setting $DRUPAL_ENV environment off maintenance mode ..."
    drush --yes @$DRUPAL_ENV vset maintenance_mode $ONLINE_MODE
}

function bootstrap_start {
    # Drupal root directory in a standardized environment
    cd ${DRUPAL_ROOT}

    if [ ! -r sites/default/default.settings.php ]; then
        $ECHO "$(basename $0) must be run from within a drupal project." >&2
        exit 1
    fi
    # First we need to drop and recreate (empty) the DB for drupal using our test user account
    mysqladmin -f -u$DB_USER -p$DB_PASS drop ${DB_NAME} || $ECHO "Notice: Not dropping missing database $DB_NAME."
    mysqladmin -u$DB_USER -p$DB_PASS create ${DB_NAME} 

    # Fix permissions to be able to start a fresh site installation
    chmod 755 sites/default
    default_settings='sites/default/settings.php'
    cp -f sites/default/default.settings.php "$default_settings"
    chmod 755 "$default_settings"

    ## Add extra steps here if necessary

    # Launch site installation. It will create database structure and edit settings.php
    if ! drush si --yes --locale="fr" --db-url="mysql://$DB_USER:$DB_PASS@localhost/${DB_NAME}" --site-name="Nom du site" standard --account-name=admin --account-pass=admin
    then
        $ECHO "Fail to create DB" >&2
        exit 1
    fi

    # Setup signal handler so DB are always deleted
    trap bootstrap_end 0
    trap "exit 2" 1 2 3 13 15

    # Eventually, load here a set of sample data
    # mysql -uDB_USER -p$DB_PASS ${DB_NAME} < $WORKSPACE/data_sample.sql
    # Display drush status
    if ! drush @self status
    then
        $ECHO "Failed to get status" >&2
        exit 1
    fi
}

function bootstrap_end {
    # Drop this build database
    true
}

function hook_invoke {
  $ECHO `ls -l $WORKSPACE`
  hook=$1

  if [[ -x "$WORKSPACE/$hook" ]]
  then
    $ECHO "Executing $hook ..." >&2
    $WORKSPACE/$hook
  else
    $ECHO "File $hook is not executable or found in $WORKSPACE" >&2
  fi 
}

if ! type drush
then
    $ECHO 'You must install drush to deploy' >&2
    exit 1
fi

# Pre-bootstrap hook
hook_invoke pre-bootstrap

# Instantiate DB
bootstrap_start

# Post-bootstrap hook
hook_invoke post-bootstrap


# Parse parameters
case "${action}" in
    deploy_dev)
        DRUPAL_ENV=dev
        if ! drush @${DRUPAL_ENV} status; then
            $ECHO "Failed to get ${DRUPAL_ENV} status" >&2
            exit 1
        fi
        # Deploy code from latest revision to staging
        site_deploy
        ;;

    deploy_test)
        DRUPAL_ENV=test
        if ! drush @${DRUPAL_ENV} status; then
            $ECHO "Failed to get ${DRUPAL_ENV} status" >&2
            exit 1
        fi
        # Deploy code from latest revision to staging
        site_deploy
        ;;
    deploy_prod)
        DRUPAL_ENV=prod
        if [ "${branch}" != 'prod' ]; then
            $ECHO "Only \'prod\' branch is deployable in production" >&2
            exit 1
        fi
        if ! drush @${DRUPAL_ENV} status; then
            $ECHO "Failed to get ${DRUPAL_ENV} status" >&2
            exit 1
        fi
        # Deploy code from latest revision to prod
        site_deploy
        ;;
    sqlsync_self_to_test)
        DRUPAL_ENV=staging
        # Sync database from live to staging
        drush --yes sql-sync @self @test
        # Sync only files
        # drush --yes @staging rsync @live:%files @self:%files
        ;;
    test_connect_prod)
        DRUPAL_ENV=prod
        if ! drush @${DRUPAL_ENV} status; then
            $ECHO "Failed to get ${DRUPAL_ENV} status" >&2
            exit 1
        else
          $ECHO "Connection successful"
          exit 0
        fi
        ;; 
    *)
        $ECHO 'Unsupported action' >&2
        exit 1
        ;;
esac

# Common actions
# Post-action hook 
# hook_invoke post-action

# Clear all cache
$ECHO "Clearing cache on $DRUPAL_ENV environment ..."
drush --yes @$DRUPAL_ENV cache-clear all

# Post-roll hook 
# hook_invoke post-roll
