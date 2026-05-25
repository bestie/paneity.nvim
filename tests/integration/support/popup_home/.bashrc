# Fixture .bashrc used by paneity integration tests.
# When a test points $HOME at tests/integration/support/popup_home,
# the popup-shell launches a bash that sources this file. Assertions
# can then check for these markers to confirm user init was sourced.

export PANEITY_TEST_MARKER=1
alias ptest='echo PTEST'

# A known, plain PS1 so capture-pane assertions can grep for the prompt
# without dealing with the developer's local PS1 styling.
#
# PANEITY_PROFILE_LOADED is set by the fixture ~/.profile. Embedding
# it in PS1 lets a test distinguish "rcfile sourced ~/.profile" (PS1
# prefix is "yes_") from "did not" (prefix is "no_"). The shorter
# "paneity_test>" suffix still appears in either case, so other tests
# that grep for it stay green.
PS1="${PANEITY_PROFILE_LOADED:-no}_paneity_test> "
