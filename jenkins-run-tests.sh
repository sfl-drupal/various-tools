#!/bin/bash

set -e

# Check this for long args example https://gist.github.com/cosimo/3760587

# Get params from build
TAG=$1
# Change this if needed
if [ -r ~/.drush-deploy.rc ]; then
    source ~/.drush-deploy.rc
else
    DB_USER=testuser
    DB_PASS=testuser
    DB_NAME=drupal
fi

# Do not edit after
EN_CODER=0
EN_PHPCPD=0
EN_PHPMD=0
EN_TESTS=0
EN_BEHAT=0
E_OPTERR=65

DRUPAL_ROOT="$WORKSPACE"/src
DRUPAL_ROOT_LEGACY="$WORKSPACE"

CUSTOMDIR="$WORKSPACE"/src/sites/all/modules/custom
CUSTOMDIR_LEGACY="$WORKSPACE"/sites/all/modules/custom

function display_usage {
  echo "Usage :   
  -c, --coder
    Checkstyle of custom modules
    Report type : Checkstyle results  
    files -> logs/coder-*.xml

  -d, --phpcpd
    Copy paste detector of custom modules
    Report type : PMD results
    file -> logs/phpmd-drupal.xml

  -m, --phpmd
    Check Duplicate code of custom modules
    Report type : Duplicate code results
    file -> logs/phpcpd-drupal.xml

  -t, --tests
    Run Simple test
    Report type : XML report Junits
    files -> logs/tests/*.xml

  -b, --behat
    Run behat unitary tests
    Report type : XML report Junits
    files -> logs/behat/*.xml
  
  -l, --legacy
    Enable Legacy drupal Organisation Folders

  Example :    
    ./jenkins.sh -c -d -m -t -b
    ./jenkins.sh -cdmtb
    ./jenkins.sh --coder --phpcpd --phpmd --tests --behat
  "
}

function drupal_legacy {
  if [ -d "$DRUPAL_ROOT" ]; then
    echo "Drupal not appear to be legacy. Verify your installation."
    exit E_OPTERR
  else
    DRUPAL_ROOT=$DRUPAL_ROOT_LEGACY
    CUSTOMDIR=$CUSTOMDIR_LEGACY
  fi
}

function drupal_install {

  #We need tocreate an empty DB for drupal using our test user account
  mysqladmin -f -u$DB_USER -p$DB_PASS drop $DB_NAME
  mysqladmin -u$DB_USER -p$DB_PASS create $DB_NAME
  
  cd $DRUPAL_ROOT

  # Launch site installation. It will create database structure and edit settings.php
  # Install site
    if ! drush si --yes --locale="fr" --db-url="mysql://$DB_USER:$DB_PASS@localhost/${DB_NAME}" --site-name="Portail de Polytechnique" portail --account-name=admin --account-pass=4m1g02014 --clean-url=1
  then
      echo "Fail to site install"
      exit 1
  fi

  # Revert all features
  drush features-revert-all -y

  # Load translations
  drush po-import fr --custom-only --replace

  drush vset clean_url 1

  # Setup signal handler so DB are always deleted
  trap script_end 0
  trap "exit 2" 1 2 3 13 15

  if ! drush status
  then
      echo "Failed to get status"
      exit 1
  fi
}

function script_end {
  # Drop this build database
  echo "Nothing to do here."
}

function run_coder { 
  echo "run_coder START"

  if [ -d "$CUSTOMDIR" ]; then
    mkdir -p ${WORKSPACE}/logs/coder
    cd $DRUPAL_ROOT
    drush dl coder --yes
    drush en coder coder_review --yes
    MODULES=$(ls -d $CUSTOMDIR)
    #Run coder against our modules
    for MOD in $MODULES; do
      drush coder-review --checkstyle --major --severity --comment --druplart --security --sql --sniffer --style $MOD > ${WORKSPACE}/logs/coder/coder-$MOD.xml 2> /dev/null
    done
  else
    echo "Nothing for coder in $CUSTOMDIR"
  fi
}

function run_phpcpd {
  echo "run_phpcpd START"

  if [ -d "$CUSTOMDIR" ]; then
    mkdir -p ${WORKSPACE}/logs/phpcpd
    # Run Copy/Paste detector
    phpcpd --log-pmd ${WORKSPACE}/logs/phpcpd/phpcpd-drupal.xml $CUSTOMDIR
  else
    echo "Nothing for phpcpd in $CUSTOMDIR"
  fi
}

function run_phpmd { 
  echo "run_phpmd START"

  if [ -d "$CUSTOMDIR" ]; then
    mkdir -p ${WORKSPACE}/logs/phpmd
    # Run PHP MEss Detector on our custom modules
    phpmd $CUSTOMDIR xml codesize,unusedcode,naming --reportfile ${WORKSPACE}/logs/phpmd/phpmd-drupal.xml 2> /dev/null
  else
    echo "Nothing for phpmd in $CUSTOMDIR"
  fi
}

function run_tests { 
  echo "run_tests START"
  
  mkdir -p ${WORKSPACE}/logs/tests
  cd $DRUPAL_ROOT
  drush en simpletest --yes
  drush vset clean_url 0
  php scripts/run-tests.sh --php /usr/bin/php --color --url http://test-amideploy --verbose --xml ${WORKSPACE}/logs/tests System
}

function run_behat { 
  echo "run_behat START"
  mkdir -p ${WORKSPACE}/logs/behat
  #Behat tests
  #Init for initialise the yml config of behat
  cd ${WORKSPACE}/test/behat
  ./behat --ansi --format junit,pretty --out ${WORKSPACE}/logs/behat,
}

function run_all_tests {
  if [ $EN_CODER -eq 1 ]; then
    run_coder
  fi
  if [ $EN_PHPCPD -eq 1 ]; then
    run_phpcpd
  fi
  if [ $EN_PHPMD -eq 1 ]; then
    run_phpmd
  fi
  if [ $EN_TESTS -eq 1 ]; then
    run_tests
  fi
  if [ $EN_BEHAT -eq 1 ]; then
    run_behat
  fi
}

function build_artefacts {
  # Export code and database. This is a test for Pantheon
  # Creating a code archive
  # Specify the destination folder
  TARGET=$WORKSPACE/build
  # Specify the source folder
  SOURCE=$WORKSPACE/src
  # Change directory to the source folder
  cd $SOURCE
  # Create an archive that excludes sites/default/files
  drush archive-dump --tar-options="--exclude=.git" --destination=$TARGET/stm_formation_mpm10-archive.tar.gz --overwrite

  # Create a compressed database backup
  drush sql-dump | gzip -9 > $TARGET/db.sql.gz
}

# Update submodules
git submodule init
git submodule update
git checkout ${BRANCH}

if [ -z "$*" ]; then
  display_usage
  # exit $E_OPTERR
else
  OPTS=`getopt -o cdmtbl --long coder,phpcpd,phpmd,tests,behat,legacy -- "$@"`
  if [ $? != 0 ] ; then 
    echo "Failed parsing options."
    display_usage
    exit $E_OPTERR
  fi
  eval set -- "$OPTS"
fi

while true; do
  case "$1" in
    -c | --coder  ) EN_CODER=1; shift ;;
    -d | --phpcpd ) EN_PHPCPD=1; shift ;;
    -m | --phpmd  ) EN_PHPMD=1; shift ;;
    -t | --tests  ) EN_TESTS=1; shift ;;
    -b | --behat  ) EN_BEHAT=1; shift ;;
    -l | --legacy ) drupal_legacy; shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

drupal_install
run_all_tests

# SUCCESS if we are here
exit 0
