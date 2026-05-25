# Fixture .profile for paneity integration tests.
#
# Bash's login-shell startup picks the first of ~/.bash_profile,
# ~/.bash_login, ~/.profile. The fixture intentionally provides
# only this one — tests assert that when neither bash_profile nor
# bash_login exists, the popup rcfile falls back to ~/.profile.

PANEITY_PROFILE_LOADED=yes
