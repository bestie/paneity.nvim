# Fixture .bashrc used by paneity integration tests.
# When a test points $HOME at tests/integration/support/popup_home,
# the popup-shell launches a bash that sources this file. Assertions
# can then check for these markers to confirm user init was sourced.

export PANEITY_TEST_MARKER=1
alias ptest='echo PTEST'

# A known, plain PS1 so capture-pane assertions can grep for the prompt
# without dealing with the developer's local PS1 styling.
PS1='paneity_test> '
