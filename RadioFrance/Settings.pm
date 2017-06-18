package Plugins::RadioFrance::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

my $prefs = preferences('plugin.radiofrance');

# Returns the name of the plugin. The real 
# string is specified in the strings.txt file.
sub name {
	return 'PLUGIN_RADIOFRANCE';
}

# The path points to the HTML page that is used to set the plugin's settings.
# The HTML page is in some funky HTML-like format that is used to display the 
# settings page when you select "Settings->Extras->[plugin's settings box]" 
# from the SC7 window.
sub page {
	return 'plugins/RadioFrance/settings/basic.html';
}

sub prefs {
	return ($prefs, qw(disablealbumname showprogimage appendlabel appendyear) );
}

# Always end with a 1 to make Perl happy
1;
