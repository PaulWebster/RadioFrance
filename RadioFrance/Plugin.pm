# Slimerver/LMS PlugIn to get Metadata from Radio France stations
# Copyright (C) 2017 - 2021 Paul Webster
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# Paul Webster - paul@dabdig.com
# This started life using ideas from DRS Meta parser by Michael Herger
# The presentation of on-demand content is based on code from Stuart McLean (expectingtofly) https://github.com/expectingtofly/
#

package Plugins::RadioFrance::Plugin;

use utf8;
use strict;
use warnings;

use vars qw($VERSION);
use HTML::Entities;
use Digest::SHA1;
use Digest::MD5 qw(md5_hex);
use HTTP::Request;

use Date::Parse;
use POSIX qw(strftime);
use File::Spec::Functions qw(:ALL);

use base qw(Slim::Plugin::OPMLBased);


use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Cache;
use Plugins::RadioFrance::Settings;

# use JSON;		# JSON.pm Not installed on all LMS implementations so use LMS-friendly one below
use JSON::XS::VersionOneAndTwo;
use Encode;
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;

use constant false => 0;
use constant true  => 1;

#temporary hack
my $getschedulehack = true;

my $pluginName = 'radiofrance';

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.'.$pluginName,
	'description'  => getDisplayName(),
});

my $prefs = preferences('plugin.'.$pluginName);

use constant cacheTTL => 20;
use constant maxSongLth => 900;		# Assumed maximum song length in seconds - if appears longer then no duration shown
use constant maxShowLth => 14400;	# Assumed maximum programme length in seconds - if appears longer then no duration shown
					# because might be a problem with the data
					# Having no duration should mean earlier call back to try again
					
					# Where images of different sizes are available (and can be determined) from the source then
					# try to keep them to no more than indicated - applies to cover art and programme logo
use constant maxImgWidth => 340;
use constant maxImgHeight => 340;

my $cache = Slim::Utils::Cache->new();
sub flushCache { $cache->cleanup(); }

my $dumped;
# If no image provided in return then try to create one from 'visual' or 'visualbanner'
my $imageapiprefix = 'https://api.radiofrance.fr/v1/services/embed/image/';
my $imageapisuffix = '?preset=400x400';

# GraphQL queries for data from Radio France - insert the numeric station id between prefix1 and prefix2
my $type3prefix1fip = 'https://www.fip.fr/latest/api/graphql?operationName=NowList&variables=%7B%22bannerPreset%22%3A%22266x266%22%2C%22stationIds%22%3A%5B';
my $type3prefix2fip = '%5D%7D';
my $type3suffix    = '&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22a6f39630b68ceb8e56340a4478e099d05c9f5fc1959eaccdfb81e2ce295d82a5%22%7D%7D';
my $type3suffixfip = '&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22151ca055b816d28507dae07f9c036c02031ed54e18defc3d16feee2551e9a731%22%7D%7D&timestamp=${unixtime}';

# Example https://www.radiofrance.fr/api/v1.9/stations/fip/webradios/fip_hiphop
# my $type4prefix = 'https://www.radiofrance.fr/api/v1.9/stations/fip/webradios/';
# until Oct-2023 - my $type4prefix = 'https://www.radiofrance.fr/api/v2.1/stations/fip/live/webradios/';
# until Nov-2024 - my $type4prefix = 'https://www.radiofrance.fr/fip/api/live/webradios/';
my $type4prefix = 'https://www.radiofrance.fr/fip/api/live?webradio=';
my $type4suffix = '';

my $type5prefix = 'https://www.radiofrance.fr/francemusique/';
my $type5suffix = '/api/webradio';

# until Nov-2024 - my $type6prefix = 'https://www.radiofrance.fr/francebleu/';
# until Nov-2024 - my $type6suffix = '/api/webradio';
my $type6prefix = 'https://www.radiofrance.fr/francebleu/api/live?webradio=';
my $type6suffix = '';

my $type7prefix = 'https://www.radiofrance.fr/franceinter/api/live?webradio=';
my $type7suffix = '';

my $type8prefix = 'https://www.radiofrance.fr/fip/api/live?';
my $type8suffix = '';

my $type9prefix = 'https://www.radiofrance.fr/fip/api/live?webradio=';
my $type9suffix = '';

my $type10prefix = 'https://api.radiofrance.fr/livemeta/live/';
my $type10suffix = '/inter_player';
my $type10asuffix = '/new_apprf_bleu';	# special for Frabce Blue (ici)

my $type11prefix = 'https://www.francebleu.fr/api/live-locale/';
my $type11suffix = '';

my $radiofrancescheuleurl = 'https://api.radiofrance.fr/v1/stations/${stationid}/steps?filter[depth]=1&filter[start-time]=${datestring}T00:00&filter[end-time]=${datestring}T23:59&fields[shows]=title,visuals,stationId,mainImage&fields[diffusions]=title,startTime,endTime,mainImage,visuals,stationId&include=diffusion&include=show&include=diffusion.manifestations&include=diffusion.station&include=children-steps&include=children-steps.show&include=children-steps.diffusion&include=children-steps.diffusion.manifestations';
my %radiofranceapiondemandheaderset = ( 'x-token' => '0cbe991e-18ac-4635-ad7f-773257c63797' );	# token as used by Radio France web interface

# URL for remote web site that is polled to get the information about what is playing
#
my $progListPerStation = true;	# Flag if programme list fetches are per station or for all stations (optimises fetches)

my $trackInfoPrefix = '';
my $trackInfoSuffix = '';

my $progInfoPrefix = '';
my $progInfoSuffix = '';

my $progDetailsURL = '';

# note - not used much (if at all) in this plugin but imported from Radio Now Playing to aid re-use of routines
my $globalSettings = {
	coversearchurl => 'http://www.dabdig.co.uk/coversearch/coversearch.php?station=${stationname}&stationid=${externalstationid}&artist=${songartist}&track=${songtitle}&album=${songalbum}&label=${songlabel}&year=${songyear}&trackid=${trackid}&ver=${pluginname}-${pluginversion}',
	coverignoreextension => false,
	assumeutf => false,
	timetextaltregex => '^(?<mth>[0-3][0-9])-(?<day>[0-9][0-9])-(?<year>[0-9][0-9][0-9][0-9]) (?<hour>[0-2][0-9]):(?<min>[0-5][0-9]):(?<sec>[0-5][0-9])',	# A US date/time format
	songpost => 'none',
	songpost_alt => 'none',
	progpost => 'none',
	progpost_alt => 'none',
	songListPerStation => true,
	songmatch => false,
	songdataurl => '',
	addcomposer => false,
	coverencode => false,
	mustsplit => false,
	artistregexmandatory => false,
	titleregexmandatory => false,
	albumregexmandatory => false,
	labelregexmandatory => false,
	trackidregexmandatory => false,
	durationregexmandatory => false,
	progtitleregexmandatory => false,
	progsubtitleregexmandatory => false,
	coverpathabsolute => false,
	progiconpathabsolute => false,
	autoregister => false,		# do not risk setting to true because it could change all station matches
	autoregisterwithoutwildcard => false,	# use this to change the behaviour of url registration for autoregister broadcasters - true stops .* which reduces false matches
	stationautoreg => true,
	stationmetaurl => '',
	maxstringlth => {
		songartist => 255,
		songtitle => 255,
		songcomposer => 255,
		songalbum => 255,
		songlabel => 127,
		trackid => 32,
		progtitle => 255,
		progsubtitle => 255,
		progsynopsis => 255,
		stationdesc => 511
	},
	httpversion => 'HTTP/1.0',
	ignoresongifsameasprog => false,	# usually ignore prog if same as song so this can be used to reverse it
	titleseparator => ' ',
	progtitleseparator => ' ',
	progsubtitleseparator => ' ',
	datetimeseparator => ' ',
	imageproxyservice => true,
	forceimageproxyforicon => false,
	allowzeroduration => false,
	defaultsonglth => 0,
	forcecaps => false,
	broadcasterfetchinthrs => 24,
	accesstoken => '',
	exactmatchurl => false,		# try to match full stream URL without regex
	xmlspecialkeys => false,
	removeonnosong => false,
	progunsorted => false,		# provided programme list is known to be unsorted
	songunsorted => false,		# provided song list is known to be unsorted
	proglistperstation => true,
	broadcasterpost => 'none',
	e24notsimulcast => false, 	# special for KCRW Elecectic24 overnight simulcast
	showsearchmenu => false,
	songendtolerance => 30,
	tracelevel => 0
};

my $provider = 'radiofrance';
# broadcasterSet contains information about "brands" or subsets of stations
# Generated from external json/xml file - left here as a documentation aid but external file is the master
# novafr => {name => 'Nova France',
		# icon => 'https://www.nova.fr/wp-content/uploads/sites/2/2020/10/NOVA_CARD_HD.png?w=450&quality=100',
		# brands => [ { name => 'Nova France', 
			      # icon => 'https://www.nova.fr/wp-content/uploads/sites/2/2020/10/NOVA_CARD_HD.png?w=450&quality=100',
			      # id => 'novafr'
			    # }
			  # ],
		# timezone => { area => 'Europe', location => 'Paris' },
		# timezonereturn => {},
		# },
my $broadcasterSet = {
	dummy => { name => 'dummy',	# No name means not a real broadcaster but needed something present for other code to work transparently
		   timezonereturn => {}, },
	radiofrance => {
		name => 'Radio France',
		artistsignoreregex => '(^| )(ici|France)(\W|$)',		# try to ignore "ici" stations guessed songs where it is really a sub-section of a programme
		timezonereturn => {},
	}
};


my $stationSet = { # Take extra care if pasting in from external spreadsheet ... station name with single quote, TuneIn ids, longer match1 for duplicate
	fipradio => { fullname => 'FIP', stationid => '7', fetchid => 'fip', region => '', tuneinid => 's15200', notexcludable => true, match1 => '', match2 => 'fip', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset, guesssong => true },
	fipbordeaux => { fullname => 'FIP Bordeaux', stationid => '7', fetchid => 'fip', region => '', tuneinid => 's50706', notexcludable => true, match1 => 'fipbordeaux', match2 => '' },
	fipnantes => { fullname => 'FIP Nantes', stationid => '7', fetchid => 'fip', region => '', tuneinid => 's50770', notexcludable => true, match1 => 'fipnantes', match2 => '' },
	fipstrasbourg => { fullname => 'FIP Strasbourg', stationid => '7', fetchid => 'fip', region => '', tuneinid => 's111944', notexcludable => true, match1 => 'fipstrasbourg', match2 => '' },
	fiprock => { fullname => 'FIP Rock', stationid => '64', fetchid => 'fip_rock', region => '', tuneinid => 's262528', notexcludable => true, match1 => 'fip-webradio1.', match2 => 'fiprock' },
	fipjazz => { fullname => 'FIP Jazz', stationid => '65', fetchid => 'fip_jazz', region => '', tuneinid => 's262533', notexcludable => true, match1 => 'fip-webradio2.', match2 => 'fipjazz' },
	fipgroove => { fullname => 'FIP Groove', stationid => '66', fetchid => 'fip_groove', region => '', tuneinid => 's262537', notexcludable => true, match1 => 'fip-webradio3.', match2 => 'fipgroove' },
	fipmonde => { fullname => 'FIP Monde', stationid => '69', fetchid => 'fip_world', region => '', tuneinid => 's262538', notexcludable => true, match1 => 'fip-webradio4.', match2 => 'fipworld' },
	fipnouveau => { fullname => 'Tout nouveau, tout Fip', stationid => '70', fetchid => 'fip_nouveautes', region => '', tuneinid => 's262540', notexcludable => true, match1 => 'fip-webradio5.', match2 => 'fipnouveautes' },
	fipreggae => { fullname => 'FIP Reggae', stationid => '71', fetchid => 'fip_reggae', region => '', tuneinid => 's293090', notexcludable => true, match1 => 'fip-webradio6.', match2 => 'fipreggae' },
	fipelectro => { fullname => 'FIP Electro', stationid => '74', fetchid => 'fip_electro', region => '', tuneinid => 's293089', notexcludable => true, match1 => 'fip-webradio8.', match2 => 'fipelectro' },
	fipmetal => { fullname => 'FIP Metal', stationid => '77', fetchid => 'fip_metal', region => '', tuneinid => 's308366', notexcludable => true, match1 => 'fip-webradio7.', match2 => 'fipmetal' },
	fippop => { fullname => 'FIP Pop', stationid => '78', fetchid => 'fip_pop', region => '', tuneinid => '', notexcludable => true, match1 => 'fip-webradio8.', match2 => 'fippop' },
	fiphiphop => { fullname => 'FIP Hip-Hop', stationid => 'fip_hiphop', fetchid => 'fip_hiphop', region => '', tuneinid => '', notexcludable => true, match1 => '', match2 => 'fiphiphop' },
	fipsacre => { fullname => 'FIP Sacré français !', stationid => 'fip_sacre_francais', fetchid => 'fip_sacre_francais', region => '', tuneinid => '', notexcludable => true, match1 => '', match2 => 'fipsacrefrancais' },

	fmclassiqueeasy => { fullname => 'France Musique Classique Easy', stationid => '401', fetchid => 'francemusique_classique_easy', region => '', tuneinid => 's283174', notexcludable => true, match1 => 'francemusiqueeasyclassique', match2 => '' },
	fmbaroque => { fullname => 'France Musique La Baroque', stationid => '408', fetchid => 'francemusique_baroque', region => '', tuneinid => 's309415', notexcludable => true, match1 => 'francemusiquebaroque', match2 => '' },
	fmclassiqueplus => { fullname => 'France Musique Classique Plus', stationid => '402', fetchid => 'francemusique_classique_plus', region => '', tuneinid => 's283175', notexcludable => true, match1 => 'francemusiqueclassiqueplus', match2 => '' },
	fmconcertsradiofrance => { fullname => 'France Musique Concerts', stationid => '403', fetchid => 'francemusique_concert_rf', region => '', tuneinid => 's283176', notexcludable => true, match1 => 'francemusiqueconcertsradiofrance', match2 => '' },
	fmlajazz => { fullname => 'France Musique La Jazz', stationid => '405', fetchid => 'francemusique_la_jazz', region => '', tuneinid => 's283178', notexcludable => true, match1 => 'francemusiquelajazz', match2 => '' },
	fmlacontemporaine => { fullname => 'France Musique La Contemporaine', stationid => '406', fetchid => 'francemusique_la_contemporaine', region => '', tuneinid => 's283179', notexcludable => true, match1 => 'francemusiquelacontemporaine', match2 => '' },
	fmocoramonde => { fullname => 'France Musique Ocora Monde', stationid => '404', fetchid => 'francemusique_ocora_monde', region => '', tuneinid => 's283177', notexcludable => true, match1 => 'francemusiqueocoramonde', match2 => '' },
	#fmevenementielle => { fullname => 'France Musique Evenementielle', stationid => '407', fetchid => 'francemusique_evenementielle', region => '', tuneinid => 's285660&|id=s306575', notexcludable => true, match1 => 'francemusiquelevenementielle', match2 => '' }, # Special case ... 2 TuneIn Id
	fmlabo => { fullname => 'France Musique Films', stationid => '407', fetchid => 'francemusique_evenementielle', region => '', tuneinid => 's306575', notexcludable => true, match1 => 'francemusiquelabo', match2 => '' }, 
	fmopera => { fullname => 'France Musique Opéra', stationid => '409', fetchid => 'francemusique_opera', region => '', tuneinid => '', notexcludable => true, match1 => 'francemusiqueopera', match2 => '' },
	fmpianozen => { fullname => 'France Musique Piano Zen', stationid => '410', fetchid => 'francemusique_piano_zen', region => '', tuneinid => '', notexcludable => true, match1 => 'francemusiquepianozen', match2 => '' },

	mouv => { fullname => 'Mouv\'', stationid => '6', fetchid => 'mouv', region => '', tuneinid => 's6597', notexcludable => true, match1 => 'mouv', match2 => '', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset, artfromuid => true },
	mouvxtra => { fullname => 'Mouv\' Xtra', stationid => '75', fetchid => '', region => '', tuneinid => '', notexcludable => true, match1 => 'mouvxtra', match2 => '' },
	mouvclassics => { fullname => 'Mouv\' Classics', stationid => '601', fetchid => 'mouv_classics', region => '', tuneinid => 's307696', notexcludable => true, match1 => 'mouvclassics', match2 => '' },
	mouvdancehall => { fullname => 'Mouv\' Dancehall', stationid => '602', fetchid => 'mouv_dancehall', region => '', tuneinid => 's307697', notexcludable => true, match1 => 'mouvdancehall', match2 => '' },
	mouvrnb => { fullname => 'Mouv\' R\'N\'B', stationid => '603', fetchid => 'mouv_rnb', region => '', tuneinid => 's307695', notexcludable => true, match1 => 'mouvrnb', match2 => '' },
	mouvrapus => { fullname => 'Mouv\' RAP US', stationid => '604', fetchid => 'mouv_rapus', region => '', tuneinid => 's307694', notexcludable => true, match1 => 'mouvrapus', match2 => '' },
	mouvrapfr => { fullname => 'Mouv\' RAP Français', stationid => '605', fetchid => 'mouv_rapfr', region => '', tuneinid => 's307693', notexcludable => true, match1 => 'mouvrapfr', match2 => '' },
	mouvkidsnfamily => { fullname => 'Mouv\' Kids\'n Family', stationid => '606', fetchid => 'mouv_kids_n_family', region => '', tuneinid => '', notexcludable => true, match1 => 'mouvkidsnfamily', match2 => '' },
	mouv100mix => { fullname => 'Mouv\' 100\% Mix', stationid => '75', fetchid => 'mouv_100mix', region => '', tuneinid => 's244069', notexcludable => true, match1 => 'mouv100p100mix', match2 => '' },
	mouvsansblabla => { fullname => 'Mouv\' Sans Blabla', stationid => 'mouvsansblabla', fetchid => 'mouv_sans_blabla', region => '', tuneinid => '', notexcludable => true, match1 => 'mouvsansblabla', match2 => '' },

	franceinter => { fullname => 'France Inter', stationid => '1', fetchid => '', region => '', tuneinid => 's24875', notexcludable => false, match1 => 'franceinter', match2 => '', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset },
	franceinterlamusiqueinter => { fullname => 'La Musique d\'Inter', stationid => 'la-musique-inter', fetchid => 'franceinter_la_musique_inter', region => '', tuneinid => '', notexcludable => false, match1 => 'franceinterlamusiqueinter', match2 => '', scheduleurl => '', artfromuid => true },

	franceinfo => { fullname => 'France Info', stationid => '2', fetchid => '', region => '', tuneinid => 's9948', notexcludable => false, match1 => 'franceinfo', match2 => '', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset, artfromuid => true },
	francemusique => { fullname => 'France Musique', stationid => '4', fetchid => 'francemusique', region => '', tuneinid => 's15198', notexcludable => false, match1 => 'francemusique', match2 => '', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset, individualprogurl => ['https://www.radiofrance.fr/api/v1.7/path?value=${progpath}', 'https://www.radiofrance.fr/api/v1.7/stations/francemusique/songs?pageCursor=Mg%3D%3D&startDate=${progstart}&endDate=${progend}&isPad=false'] },
	franceculture => { fullname => 'France Culture', stationid => '5', fetchid => 'franceculture', region => '', tuneinid => 's2442', notexcludable => false, match1 => 'franceculture', match2 => '', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset, artfromuid => true },

	# until Nov-2024 - fb100chanson => { fullname => 'France Bleu 100% Chanson Française', stationid => 'fbchansonfrancaise', fetchid => 'chanson-francaise', region => '', tuneinid => '', notexcludable => false, match1 => 'fbchansonfrancaise', match2 => '', scheduleurl => '', artfromuid => true },
	fb100chanson => { fullname => 'ici 100% Chanson Française', stationid => 'fbchansonfrancaise', fetchid => 'francebleu_chanson_francaise', region => '', tuneinid => '', notexcludable => false, match1 => 'fbchansonfrancaise', match2 => '', scheduleurl => '', artfromuid => true },
	fbalsace => { fullname => 'ici Alsace', stationid => '12', fetchid => 'alsace', region => '', tuneinid => 's2992', notexcludable => false, match1 => 'fbalsace', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbarmorique => { fullname => 'ici Armorique', stationid => '13', fetchid => 'armorique', region => '', tuneinid => 's25492', notexcludable => false, match1 => 'fbarmorique', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbauxerre => { fullname => 'ici Auxerre', stationid => '14', fetchid => 'auxerre', region => '', tuneinid => 's47473', notexcludable => false, match1 => 'fbauxerre', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbazur => { fullname => 'ici Azur', stationid => '49', fetchid => 'azur', region => '', tuneinid => 's45035', notexcludable => false, match1 => 'fbazur', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbbearn => { fullname => 'ici Béarn', stationid => '15', fetchid => 'bearn', region => '', tuneinid => 's48291', notexcludable => false, match1 => 'fbbearn', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbbelfort => { fullname => 'ici Belfort-Montbéliard', stationid => '16', fetchid => 'belfort-montbeliard', region => '', tuneinid => 's25493', notexcludable => false, match1 => 'fbbelfort', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbberry => { fullname => 'ici Berry', stationid => '17', fetchid => 'berry', region => '', tuneinid => 's48650', notexcludable => false, match1 => 'fbberry', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbbesancon => { fullname => 'ici Besançon', stationid => '18', fetchid => 'besancon', region => '', tuneinid => 's48652', notexcludable => false, match1 => 'fbbesancon', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbbourgogne => { fullname => 'ici Bourgogne', stationid => '19', fetchid => 'bourgogne', region => '', tuneinid => 's36092', notexcludable => false, match1 => 'fbbourgogne', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbbreizhizel => { fullname => 'ici Breizh Izel', stationid => '20', fetchid => 'breizh-izel', region => '', tuneinid => 's25494', notexcludable => false, match1 => 'fbbreizizel', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbchampagne => { fullname => 'ici Champagne-Ardenne', stationid => '21', fetchid => 'champagne-ardenne', region => '', tuneinid => 's47472', notexcludable => false, match1 => 'fbchampagne', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbcotentin => { fullname => 'ici Cotentin', stationid => '37', fetchid => 'cotentin', region => '', tuneinid => 's36093', notexcludable => false, match1 => 'fbcotentin', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbcreuse => { fullname => 'ici Creuse', stationid => '23', fetchid => 'creuse', region => '', tuneinid => 's2997', notexcludable => false, match1 => 'fbcreuse', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbdromeardeche => { fullname => 'ici Drôme Ardèche', stationid => '24', fetchid => 'drome-ardeche', region => '', tuneinid => 's48657', notexcludable => false, match1 => 'fbdromeardeche', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbelsass => { fullname => 'ici Elsass', stationid => '90', fetchid => 'elsass', region => '', tuneinid => 's74418', notexcludable => false, match1 => 'fbelsass', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbgardlozere => { fullname => 'ici Gard Lozère', stationid => '25', fetchid => 'gard-lozere', region => '', tuneinid => 's36094', notexcludable => false, match1 => 'fbgardlozere', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbgascogne => { fullname => 'ici Gascogne', stationid => '26', fetchid => 'gascogne', region => '', tuneinid => 's47470', notexcludable => false, match1 => 'fbgascogne', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbgironde => { fullname => 'ici Gironde', stationid => '27', fetchid => 'gironde', region => '', tuneinid => 's48659', notexcludable => false, match1 => 'fbgironde', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbherault => { fullname => 'ici Hérault', stationid => '28', fetchid => 'herault', region => '', tuneinid => 's48665', notexcludable => false, match1 => 'fbherault', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbisere => { fullname => 'ici Isère', stationid => '29', fetchid => 'isere', region => '', tuneinid => 's20328', notexcludable => false, match1 => 'fbisere', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fblarochelle => { fullname => 'ici La Rochelle', stationid => '30', fetchid => 'la-rochelle', region => '', tuneinid => 's48669', notexcludable => false, match1 => 'fblarochelle', match2 => '', ondemandurl => $radiofrancescheuleurl, ondemandheaders => \%radiofranceapiondemandheaderset, artfromuid => true, guesssong => true },  #Possible alternate for schedule https://www.francebleu.fr/grid/la-rochelle/${unixtime}
	fblimousin => { fullname => 'ici Limousin', stationid => '31', fetchid => 'limousin', region => '', tuneinid => 's48670', notexcludable => false, match1 => 'fblimousin', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbloireocean => { fullname => 'ici Loire Océan', stationid => '32', fetchid => 'loire-ocean', region => '', tuneinid => 's36096', notexcludable => false, match1 => 'fbloireocean', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fblorrainenord => { fullname => 'ici Lorraine Nord', stationid => '50', fetchid => 'lorraine-nord', region => '', tuneinid => 's48672', notexcludable => false, match1 => 'fblorrainenord', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbmaine => { fullname => 'ici Maine', stationid => '91', fetchid => 'maine', region => '', tuneinid => 's127941', notexcludable => false, match1 => 'fbmaine', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbmayenne => { fullname => 'ici Mayenne', stationid => '34', fetchid => 'mayenne', region => '', tuneinid => 's48673', notexcludable => false, match1 => 'fbmayenne', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbnord => { fullname => 'ici Nord', stationid => '36', fetchid => 'nord', region => '', tuneinid => 's44237', notexcludable => false, match1 => 'fbnord', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbbassenormandie => { fullname => 'ici Normandie (Calvados - Orne)', stationid => '22', fetchid => 'normandie-caen', region => '', tuneinid => 's48290', notexcludable => false, match1 => 'fbbassenormandie', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbhautenormandie => { fullname => 'ici Normandie (Seine-Maritime - Eure)', stationid => '38', fetchid => 'normandie-rouen', region => '', tuneinid => 's222667', notexcludable => false, match1 => 'fbhautenormandie', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbtoulouse => { fullname => 'ici Occitanie', stationid => '92', fetchid => 'toulouse', region => '', tuneinid => 's50669', notexcludable => false, match1 => 'fbtoulouse', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fborleans => { fullname => 'ici Orléans', stationid => '39', fetchid => 'orleans', region => '', tuneinid => 's1335', notexcludable => false, match1 => 'fborleans', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbparis => { fullname => 'ici Paris Île-de-France', stationid => '68', fetchid => 'paris', region => '', tuneinid => 's52972', notexcludable => false, match1 => 'fb1071', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbpaysbasque => { fullname => 'ici Pays Basque', stationid => '41', fetchid => 'pays-basque', region => '', tuneinid => 's48682', notexcludable => false, match1 => 'fbpaysbasque', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbpaysdauvergne => { fullname => 'ici Pays d&#039;Auvergne', stationid => '40', fetchid => 'pays-d-auvergne', region => '', tuneinid => 's48683', notexcludable => false, match1 => 'fbpaysdauvergne', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbpaysdesavoie => { fullname => 'ici Pays de Savoie', stationid => '42', fetchid => 'pays-de-savoie', region => '', tuneinid => 's45038', notexcludable => false, match1 => 'fbpaysdesavoie', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbperigord => { fullname => 'ici Périgord', stationid => '43', fetchid => 'perigord', region => '', tuneinid => 's2481', notexcludable => false, match1 => 'fbperigord', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbpicardie => { fullname => 'ici Picardie', stationid => '44', fetchid => 'picardie', region => '', tuneinid => 's25497', notexcludable => false, match1 => 'fbpicardie', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbpoitou => { fullname => 'ici Poitou', stationid => '54', fetchid => 'poitou', region => '', tuneinid => 's47471', notexcludable => false, match1 => 'fbpoitou', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbprovence => { fullname => 'ici Provence', stationid => '45', fetchid => 'provence', region => '', tuneinid => 's1429', notexcludable => false, match1 => 'fbprovence', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbrcfm => { fullname => 'ici RCFM', stationid => '11', fetchid => 'rcfm', region => '', tuneinid => 's48656', notexcludable => false, match1 => 'fbfrequenzamora', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbroussillon => { fullname => 'ici Roussillon', stationid => '46', fetchid => 'roussillon', region => '', tuneinid => 's48689', notexcludable => false, match1 => 'fbroussillon', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbsaintetienneloire => { fullname => 'ici Saint-Étienne Loire', stationid => '93', fetchid => 'saint-etienne-loire', region => '', tuneinid => 's212244', notexcludable => false, match1 => 'fbstetienne', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbsudlorraine => { fullname => 'ici Sud Lorraine', stationid => '33', fetchid => 'sud-lorraine', region => '', tuneinid => 's45039', notexcludable => false, match1 => 'fbsudlorraine', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbtouraine => { fullname => 'ici Touraine', stationid => '47', fetchid => 'touraine', region => '', tuneinid => 's48694', notexcludable => false, match1 => 'fbtouraine', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
	fbvaucluse => { fullname => 'ici Vaucluse', stationid => '48', fetchid => 'vaucluse', region => '', tuneinid => 's47474', notexcludable => false, match1 => 'fbvaucluse', match2 => '', scheduleurl => '', artfromuid => true, guesssong => true },
};


# $programmeMeta contains data about the scheduled programmes.
# Fetched when programme data is needed but the current time slot & station has none
# fetcheddata to contain programme information by station id (not necessarily same the the playing station ...)
# this allows stations to share programme data - e.g. kcrw and kcrwsb
my $programmeMeta = {
	whenfetchedbroadcaster => '',
	whenfetched => { allservices => '',
			 },
	whenfetchedsonglist => '',
	fetcheddata => { 
			 },
};


# URL for remote web site that is polled to get the information about what is playing
# Old URLs that used to work but were phased out are commented out as they might help in future if Radio France changes things again
# When FIP Pop was added there was only a GraphQL URL ... so maybe the livemeta/pull URLs are on the way out
# However, having both versions can lead to oddities e.g. artist names represented slightly differently when multiple so for now leave the livemeta/pull as
# primary and do not use _alt but left in the code to make it fairly easy to switch later if livemeta/pull is retired

my $urls = {
	radiofranceprogdata => '', # 
	radiofranceprogdata_alt => '',
	radiofranceondemandurl => $radiofrancescheuleurl,
	radiofranceondemandheaders => \%radiofranceapiondemandheaderset,
	radiofrancebroadcasterdata => '',
	
	# Note - loop below adds one hash for each station
# finished 1521553005 - 2018-03-20 13:36:45	fipradio_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipradio => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	# finished mid-2023 - fipradio => 'https://api.radiofrance.fr/livemeta/live/${stationid}/webrf_fip_player?preset=400x400',
	# finished Nov-2024 - fipradio => $type4prefix.'${fetchid}'.$type4suffix,
	fipradio => $type8prefix.'${fetchid}'.$type8suffix,
	fipradio_alt => $type10prefix.'${stationid}'.$type10asuffix,
# finished 1521553005 - 2018-03-20 13:36:45	fipbordeaux_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipbordeaux => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipbordeaux => $type4prefix.'${fetchid}'.$type4suffix,
	# fipbordeaux_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1521553005 - 2018-03-20 13:36:45	fipnantes_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipnantes => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipnantes => $type4prefix.'${fetchid}'.$type4suffix,
	# fipnantes_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1521553005 - 2018-03-20 13:36:45	fipstrasbourg_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipstrasbourg => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipstrasbourg => $type4prefix.'${fetchid}'.$type4suffix,
	# fipstrasbourg_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1507650288 - 2017-10-10 16:44:48	fiprock_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_1/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fiprock => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished November 2024 - fiprock => $type4prefix.'${fetchid}'.$type4suffix,
	fiprock => $type9prefix.'${fetchid}'.$type9suffix,
	# fiprock_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1507650914 - 2017-10-10 16:55:14	fipjazz_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_2/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipjazz => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipjazz => $type4prefix.'${fetchid}'.$type4suffix,
	# fipjazz_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1507650885 - 2017-10-10 16:54:45	fipgroove_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_3/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipgroove => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipgroove => $type4prefix.'${fetchid}'.$type4suffix,
	# fipgroove_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1507650800 - 2017-10-10 16:53:20	fipmonde_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_4/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipmonde => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipmonde => $type4prefix.'${fetchid}'.$type4suffix,
	# fipmonde_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1507650797 - 2017-10-10 16:53:17	fipnouveau_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_5/si_titre_antenne/FIP_player_current.json',
# finished December 2020 - fipnouveau => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipnouveau => $type4prefix.'${fetchid}'.$type4suffix,
	# fipnouveau_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished 1507650800 - 2017-10-10 16:53:20	fipevenement_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_6/si_titre_antenne/FIP_player_current.json',
# FIP Evenement became FIP Autour Du Reggae
# finished December 2020 - fipreggae => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipreggae => $type4prefix.'${fetchid}'.$type4suffix,
	# fipreggae_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fipelectro => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipelectro => $type4prefix.'${fetchid}'.$type4suffix,
	# fipelectro_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fipmetal => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fipmetal => $type4prefix.'${fetchid}'.$type4suffix,
	# fipmetal_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	fippop => $type4prefix.'${fetchid}'.$type4suffix,
	fiphiphop => $type4prefix.'${fetchid}'.$type4suffix,
	fipsacre => $type4prefix.'${fetchid}'.$type4suffix,
	
# finished December 2020 - fmclassiqueeasy => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmclassiqueeasy => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmclassiqueeasy => $type4prefix.'${fetchid}'.$type4suffix,
	# fmclassiqueeasy_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmbaroque => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmbaroque => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmbaroque => $type4prefix.'${fetchid}'.$type4suffix,
	#fmbaroque_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmclassiqueplus => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmclassiqueplus => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmclassiqueplus => $type4prefix.'${fetchid}'.$type4suffix,
	#fmclassiqueplus_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmconcertsradiofrance => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmconcertsradiofrance => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmconcertsradiofrance => $type4prefix.'${fetchid}'.$type4suffix,
	#fmconcertsradiofrance_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmlajazz => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmlajazz => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmlajazz => $type4prefix.'${fetchid}'.$type4suffix,
	#fmlajazz_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmlacontemporaine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmlacontemporaine => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmlacontemporaine => $type4prefix.'${fetchid}'.$type4suffix,
	#fmlacontemporaine_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmocoramonde => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmocoramonde => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmocoramonde => $type4prefix.'${fetchid}'.$type4suffix,
	#fmocoramonde_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	#fmevenementielle => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished December 2020 - fmlabo => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmlabo => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmlabo => $type4prefix.'${fetchid}'.$type4suffix,
	# fmlabo_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - fmopera => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - fmopera => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	fmopera => $type4prefix.'${fetchid}'.$type4suffix,
	# fmopera_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	fmpianozen => $type4prefix.'${fetchid}'.$type4suffix,
	
# finished December 2020 - mouv => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - 	mouv => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	mouv => $type4prefix.'${fetchid}'.$type4suffix,
	# mouv_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - mouvxtra => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - 	mouvxtra => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	mouvxtra => $type4prefix.'${fetchid}'.$type4suffix,
	#mouvxtra_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished July 2023 - 	mouvclassics => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A601%7D&'.$type3suffix,
	mouvclassics => $type4prefix.'${fetchid}'.$type4suffix,
	#mouvclassics_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished July 2023 - 	mouvdancehall => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A602%7D&'.$type3suffix,
	mouvdancehall => $type4prefix.'${fetchid}'.$type4suffix,
	#mouvdancehall_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished July 2023 - 	mouvrnb => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A603%7D&'.$type3suffix,
	mouvrnb => $type4prefix.'${fetchid}'.$type4suffix,
	#mouvrnb_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished July 2023 - 	mouvrapus => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A604%7D&'.$type3suffix,
	mouvrapus => $type4prefix.'${fetchid}'.$type4suffix,
	#mouvrapus_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished July 2023 - 	mouvrapfr => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A605%7D&'.$type3suffix,
	mouvrapfr => $type4prefix.'${fetchid}'.$type4suffix,
	#mouvrapfr_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	mouvkidsnfamily => $type4prefix.'${fetchid}'.$type4suffix,
# finished July 2023 - 	mouv100mix => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A75%7D&'.$type3suffix,
	mouv100mix => $type4prefix.'${fetchid}'.$type4suffix,
	#mouv100mix_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	mouvsansblabla => $type4prefix.'${fetchid}'.$type4suffix,

	
# finished December 2020 - franceinter => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	franceinter => $type10prefix.'${stationid}'.$type10suffix,
	#franceinter_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	franceinterlamusiqueinter => $type7prefix.'${fetchid}'.$type7suffix,
# finished December 2020 - franceinfo => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	franceinfo => $type10prefix.'${stationid}'.$type10suffix,
	#franceinfo_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - francemusique => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# finished July 2023 - 	francemusique => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
	francemusique => $type4prefix.'${fetchid}'.$type4suffix,
	#francemusique_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
# finished December 2020 - franceculture => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
# Removed July 2023 - franceculture => 'https://api.radiofrance.fr/livemeta/live/${stationid}/inter_player',
# retired Mar-2024 - franceculture => 'https://www.radiofrance.fr/api/v2.1/stations/franceculture/live',
	franceculture => $type4prefix.'${fetchid}'.$type4suffix,
	#franceculture_alt => $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip,
	
	fb100chanson => $type6prefix.'${fetchid}'.$type6suffix,
	# Limited song data from France Bleu local stations
	# Possible alternative source for programme info ...
	# https://www.francebleu.fr/grid/alsace/1641206097?xmlHttpRequest=1&ignoreGridHour=1
	# Jan-2025 - for all fb (ici) stations changed from $type10prefix.'${stationid}'.$type10suffix to $type10prefix.'${stationid}'.$type10asuffix
	# this brings more icons and also they seem to hide song info in line2 - but not parsing it along with cover art
	# could use $type11prefix.'${fetchid}'.$type11suffix - but they seem not to put song info in and have fewer icons
	# this alternative URL usually returns data including link to programmme icon
#finished December 2020 - fbalsace => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbalsace => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbarmorique => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbarmorique => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbauxerre => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbauxerre => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbazur => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbazur => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbbearn => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbearn => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbbelfort => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbelfort => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbberry => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbberry => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbbesancon => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbesancon => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbbourgogne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbourgogne => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbbreizhizel => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbreizhizel => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbchampagne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbchampagne => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbcotentin => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbcotentin => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbcreuse => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbcreuse => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbdromeardeche => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbdromeardeche => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbelsass => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbelsass => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbgardlozere => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbgardlozere => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbgascogne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbgascogne => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbgironde => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbgironde => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbherault => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbherault => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbisere => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbisere => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fblarochelle => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fblarochelle => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fblimousin => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fblimousin => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbloireocean => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbloireocean => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fblorrainenord => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fblorrainenord => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbmaine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbmaine => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbmayenne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbmayenne => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbnord => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbnord => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbbassenormandie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbassenormandie => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbhautenormandie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbhautenormandie => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbtoulouse => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbtoulouse => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fborleans => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fborleans => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbparis => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbparis => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbpaysbasque => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpaysbasque => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbpaysdauvergne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpaysdauvergne => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbpaysdesavoie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpaysdesavoie => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbperigord => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbperigord => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbpicardie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpicardie => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbpoitou => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpoitou => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbprovence => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbprovence => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbrcfm => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbrcfm => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbroussillon => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbroussillon => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbsaintetienneloire => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbsaintetienneloire => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbsudlorraine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbsudlorraine => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbtouraine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbtouraine => $type10prefix.'${stationid}'.$type10asuffix,
#finished December 2020 - fbvaucluse => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbvaucluse => $type10prefix.'${stationid}'.$type10asuffix,
};

foreach my $metakey (keys(%$stationSet)){
	# Inialise the URL table - do not replace items that are already present (to allow override)
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising urls - $metakey");
	if ( not exists $urls->{$metakey} ){
		$urls->{$metakey} = $type3prefix1fip.'${stationid}'.$type3prefix2fip.$type3suffixfip;
	}
}

# Potential place for logos - https://charte.dnm.radiofrance.fr/logos.php
# Also - https://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/radio-france.png
my $icons = {
	#fipradio => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fipradio => 'http://oblique.radiofrance.fr/files/charte/logos/png600/FIP.png',
	fipbordeaux => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fipnantes => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fipstrasbourg => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fiprock => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/300x300_fip-rock_ok.jpg',
	fipjazz => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/840a4431-0db0-4a94-aa28-53f8de011ab6/300x300_fip-jazz-01.jpg',
	fipgroove => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/3673673e-30f7-4caf-92c6-4161485d284d/300x300_fip-groove_ok.jpg',
	fipmonde => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/9a1d42c5-8a36-4253-bfae-bdbfb85cbe14/300x300_fip-monde_ok.jpg',
	fipnouveau => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/e061141c-f6b4-4502-ba43-f6ec693a049b/300x300_fip-nouveau_ok.jpg',
	fipreggae => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/15a58f25-86a5-4b1a-955e-5035d9397da3/300x300_fip-reggae_ok.jpg',
	fipelectro => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/29044099-6469-4f2f-845c-54e607179806/300x300_fip-electro-ok.jpg',
	fipmetal => 'https://www.radiofrance.fr/s3/cruiser-production/2022/07/160994f8-296b-4cd8-97a0-34c9111cdd9d/300x300_fip-metal-20222x_2.jpg',
	fippop => 'https://cdn.radiofrance.fr/s3/cruiser-production/2020/06/14f16d25-960c-4cf4-8e39-682268b1a0c1/300x300_fip-pop_ok.jpg',
	fiphiphop => 'https://www.radiofrance.fr/s3/cruiser-production/2022/07/af67eb80-feac-441e-aea6-ba7c653e220d/300x300_fip-hip-hop-2022-v12x-1.jpg',
	fipsacre => 'https://www.radiofrance.fr/s3/cruiser-production/2023/07/562152b5-9c46-46c1-a166-683448aa1fbe/250x250_sc_sacre-franaais.jpg',
	
	fmclassiqueeasy => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/36c9fa83-a2c6-4432-9234-36f22ddabc24/300x300_webradios_fm_classique-easy.jpg',
	fmbaroque => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/544d1b3c-fc0f-462d-bc6e-f96bb199c672/300x300_webradios_fm_la-baroque.jpg',
	fmclassiqueplus => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/4eb2980e-2d53-4f4c-ba9d-ddbf3e96b9d8/300x300_webradios_fm_classique-plus.jpg',
	fmconcertsradiofrance => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/c9c1dacf-6fc5-49ef-ac9e-7fa6145fd850/300x300_webradios_fm_concerts-radio-france.jpg',
	fmlajazz => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/13381986-e962-4809-ad21-23e8260c8f75/300x300_webradios_fm_la-jazz.jpg',
	fmlacontemporaine => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/b365b09f-8ca2-4ae3-beda-d45711df7a49/300x300_webradios_fm_la-contemporaine.jpg',
	fmocoramonde => 'https://cdn.radiofrance.fr/s3/cruiser-production/2022/02/75db3a09-1545-487b-ab11-81db3642a5cd/300x300_webradios_fm_musiques-du-monde-ocora.jpg',
	#fmevenementielle => 'https://cdn.radiofrance.fr/s3/cruiser-production/2017/06/d2ac7a26-843d-4f0c-a497-8ddf6f3b2f0f/200x200_fmwebbotout.jpg',
	fmlabo => 'https://www.radiofrance.fr/s3/cruiser-production/2023/05/4f0b91f5-d507-4924-b3c2-518a9c087aec/300x300_sc_musique-de-films.jpg',
	fmopera => 'https://cdn.radiofrance.fr/s3/cruiser-production/2020/10/c1fb2b03-5c04-42c9-b415-d56e4c61dcd9/fm-opera-webradio2x.png',
	fmpianozen => 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/02/2ed60106-b535-4949-8a40-5636bb0d9979/300x300_sc_fm_webradios_pianozen_1400x1400.jpg',
	
	#mouv => 'https://www.radiofrance.fr/sites/default/files/styles/format_16_9/public/2019-08/logo_mouv_bloc_c.png.jpeg',
	mouv => 'http://oblique.radiofrance.fr/files/charte/logos/png600/Mouv.png',
	mouvxtra => 'http://www.mouv.fr/sites/all/modules/rf/rf_lecteur_commun/lecteur_rf/img/logo_mouv_xtra.png',
	mouvclassics => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/bb8da8da-f679-405f-8810-b4a172f6a32d/300x300_mouv-classic_02.jpg',
	mouvdancehall => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/9d04e918-c907-4627-a332-1071bdc2366e/300x300_dancehall.jpg',
	mouvrnb => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/f3bf764e-637c-48c0-b152-1a258726710f/300x300_rnb.jpg',
	mouvrapus => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/54f3a745-fcf5-4f62-885a-a014cdd50a62/300x300_rapus.jpg',
	mouvrapfr => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/3c4dc967-ed2c-4ce5-a998-9437a64e05d5/300x300_rapfr.jpg',
	mouv100mix => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/689453b1-de6c-4c9e-9ebd-de70d0220e69/300x300_mouv-100mix-final.jpg',
	mouvkidsnfamily => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/08/20b36ec0-fd19-4d92-b393-7977277e1452/300x300_mouv_webradio_kids_n_family.jpg',
	mouvsansblabla => 'https://cdn.radiofrance.fr/s3/cruiser-production-eu3/2024/05/59a2cea8-2046-4473-885b-92b9497175ad/300x300_sc_visuel-mouvsansblabla-vert.jpg',
	
	franceinter => 'http://oblique.radiofrance.fr/files/charte/logos/png600/FranceInter.png',	# Note - official uses https but (for now) http works and might help legacy devices
	#franceinter => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-inter.png',
	franceinterlamusiqueinter => 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/06/2eb99120-ff28-414d-a805-c354c3967edf/300x300_sc_fi-webradio-c3b2.jpg',
	
	franceinfo => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-info.png',
	#francemusique => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-musique.png',
	francemusique => 'http://oblique.radiofrance.fr/files/charte/logos/png600/FranceMusique.png',
	#franceculture => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-culture.png',
	franceculture => 'http://oblique.radiofrance.fr/files/charte/logos/png600/FranceCulture.png',
	
	# until Jan-2025 fb100chanson => 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/03/113906b6-6173-403f-bda5-8ad0d7c022a4/300x300_sc_1024.jpg',
	fb100chanson => 'https://www.francebleu.fr/client/immutable/assets/fallback-cover.CNLc2QwW.jpg',
	# until Jan-2025 fbalsace => 'plugins/RadioFrance/html/images/fbalsace_svg.png',
	# until Jan-2025 fbarmorique => 'plugins/RadioFrance/html/images/fbarmorique_svg.png',
	# until Jan-2025 fbauxerre => 'plugins/RadioFrance/html/images/fbauxerre_svg.png',
	# until Jan-2025 fbazur => 'plugins/RadioFrance/html/images/fbazur_svg.png',
	# until Jan-2025 fbbearn => 'plugins/RadioFrance/html/images/fbbearn_svg.png',
	# until Jan-2025 fbbelfort => 'plugins/RadioFrance/html/images/fbbelfort-montbeliard_svg.png',
	# until Jan-2025 fbberry => 'plugins/RadioFrance/html/images/fbberry_svg.png',
	# until Jan-2025 fbbesancon => 'plugins/RadioFrance/html/images/fbbesancon_svg.png',
	# until Jan-2025 fbbourgogne => 'plugins/RadioFrance/html/images/fbbourgogne_svg.png',
	# until Jan-2025 fbbreizhizel => 'plugins/RadioFrance/html/images/fbbreizh-izel_svg.png',
	# until Jan-2025 fbchampagne => 'plugins/RadioFrance/html/images/fbchampagne-ardenne_svg.png',
	# until Jan-2025 fbcotentin => 'plugins/RadioFrance/html/images/fbcotentin_svg.png',
	# until Jan-2025 fbcreuse => 'plugins/RadioFrance/html/images/fbcreuse_svg.png',
	# until Jan-2025 fbdromeardeche => 'plugins/RadioFrance/html/images/fbdrome-ardeche_svg.png',
	# until Jan-2025 fbelsass => 'plugins/RadioFrance/html/images/fbelsass_svg.png',
	# until Jan-2025 fbgardlozere => 'plugins/RadioFrance/html/images/fbgard-lozere_svg.png',
	# until Jan-2025 fbgascogne => 'plugins/RadioFrance/html/images/fbgascogne_svg.png',
	# until Jan-2025 fbgironde => 'plugins/RadioFrance/html/images/fbgironde_svg.png',
	# until Jan-2025 fbherault => 'plugins/RadioFrance/html/images/fbherault_svg.png',
	# until Jan-2025 fbisere => 'plugins/RadioFrance/html/images/fbisere_svg.png',
	# until Jan-2025 fblarochelle => 'plugins/RadioFrance/html/images/fbla-rochelle_svg.png',
	# until Jan-2025 fblimousin => 'plugins/RadioFrance/html/images/fblimousin_svg.png',
	# until Jan-2025 fbloireocean => 'plugins/RadioFrance/html/images/fbloire-ocean_svg.png',
	# until Jan-2025 fblorrainenord => 'plugins/RadioFrance/html/images/fblorraine-nord_svg.png',
	# until Jan-2025 fbmaine => 'plugins/RadioFrance/html/images/fbmaine_svg.png',
	# until Jan-2025 fbmayenne => 'plugins/RadioFrance/html/images/fbmayenne_svg.png',
	# until Jan-2025 fbnord => 'plugins/RadioFrance/html/images/fbnord_svg.png',
	# until Jan-2025 fbbassenormandie => 'plugins/RadioFrance/html/images/fbnormandie_svg.png',	# Wrong logo
	# until Jan-2025 fbhautenormandie => 'plugins/RadioFrance/html/images/fbnormandie_svg.png',	# Wrong logo
	# until Jan-2025 fbtoulouse => 'plugins/RadioFrance/html/images/fboccitanie_svg.png',
	# until Jan-2025 fborleans => 'plugins/RadioFrance/html/images/fborleans_svg.png',
	# until Jan-2025 fbparis => 'plugins/RadioFrance/html/images/fbparis_svg.png',
	# until Jan-2025 fbpaysbasque => 'plugins/RadioFrance/html/images/fbpays-basque_svg.png',
	# until Jan-2025 fbpaysdauvergne => 'plugins/RadioFrance/html/images/fbauvergne_svg.png',
	# until Jan-2025 fbpaysdesavoie => 'plugins/RadioFrance/html/images/fbsavoie_svg.png',
	# until Jan-2025 fbperigord => 'plugins/RadioFrance/html/images/fbperigord_svg.png',
	# until Jan-2025 fbpicardie => 'plugins/RadioFrance/html/images/fbpicardie_svg.png',
	# until Jan-2025 fbpoitou => 'plugins/RadioFrance/html/images/fbpoitou_svg.png',
	# until Jan-2025 fbprovence => 'plugins/RadioFrance/html/images/fbprovence_svg.png',
	# until Jan-2025 fbrcfm => 'plugins/RadioFrance/html/images/fbrcfm_svg.png',
	# until Jan-2025 fbroussillon => 'plugins/RadioFrance/html/images/fbroussillon_svg.png',
	# until Jan-2025 fbsaintetienneloire => 'plugins/RadioFrance/html/images/fbsaint-etienne-loire_svg.png',
	# until Jan-2025 fbsudlorraine => 'plugins/RadioFrance/html/images/fbsud-lorraine_svg.png',
	# until Jan-2025 fbtouraine => 'plugins/RadioFrance/html/images/fbtouraine_svg.png',
	# until Jan-2025 fbvaucluse => 'plugins/RadioFrance/html/images/fbvaucluse_svg.png',
	
	fbalsace=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/c57f3937-c855-4c37-bf3d-80dae44fb502/sc_logo-alsace.jpg',
	fbarmorique=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/99ac5a26-e5f0-490e-b513-38ee148c7e5a/sc_logo-armorique.jpg',
	fbauxerre=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/e2026fb2-4cab-4137-bf1e-0b5324ec2ca4/sc_logo-auxerre.jpg',
	fbazur=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/06460fe8-13db-4ec0-b98b-741c56a146d6/sc_logo-azur.jpg',
	fbbearn=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/ba415434-04bc-4c30-b350-7dcca070b935/sc_logo-bearn-bigorre.jpg',
	fbbelfort=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/f3238cc6-2f8a-4565-aa8a-d970bfac7d0a/sc_logo-belfort-montbeliard.jpg',
	fbberry=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/06bb2775-63d9-433b-af7b-f8f62f021203/sc_logo-berry.jpg',
	fbbesancon=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/e14152d8-168d-4b44-82e5-86c9c48176aa/sc_logo-besancion.jpg',
	fbbourgogne=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/4650a9b3-4395-4be8-a89d-73f61806a806/sc_logo-bourgogne.jpg',
	fbbreizhizel=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/269593ab-0229-4dc1-8625-cd19943a299d/sc_logo-beazh-izel.jpg',
	fbchampagne=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/b011edaa-d3f5-4489-9a57-eaded51894f9/sc_logo-chamagne-ardenne.jpg',
	fbcotentin=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/f6ec610c-4ae9-4128-86a5-12ad3f874636/sc_logo-cotentin.jpg',
	fbcreuse=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/4a6c076b-2049-4744-a211-bf5d811a4fe9/sc_logo-creuse.jpg',
	fbdromeardeche=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/044ffe9e-28d7-4dd3-960f-299a704ff71b/sc_logo-drome-ardeche.jpg',
	fbelsass=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/303be539-4fe2-4c8c-9b48-f5d0bc7b637f/sc_logo-elsass.jpg',
	fbgardlozere=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/06266b7e-38a5-458f-9926-3c3d8db11e4a/sc_logo-lozere.jpg',
	fbgascogne=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/be86fb63-ff3e-4d57-b8e5-e131e05c51d6/sc_logo-gascogne.jpg',
	fbgironde=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/e3a6cf54-c830-4466-bf6b-913d9b37322d/sc_logo-gironde.jpg',
	fbherault=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/536dcf8e-86ac-482a-9a95-8bfa16203a5b/sc_logo-heirault.jpg',
	fbisere=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/b862114b-7b80-4f69-9b88-e73a442522ff/sc_logo-iseire.jpg',
	fblarochelle=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/3094e84d-6b04-478f-be04-73969274e488/sc_logo-la-rochelle.jpg',
	fblimousin=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/ff4d3086-9902-44ac-98c7-649ae310ad59/sc_logo-limousin.jpg',
	fbloireocean=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/54bfa2c2-55e6-4a32-bc8a-c891a08f0626/sc_logo-oceian.jpg',
	fblorrainenord=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2025/01/eafc9a23-a5c8-4988-bbf8-c473f70a04f2/sc_logo-lorraine.jpg',
	fbmaine=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/ea9da570-4e6e-4212-b5fa-2bcd1bdb1e3a/sc_logo-maine.jpg',
	fbmayenne=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/655cca16-52bf-4eb1-aea7-2114bb6a2b46/sc_logo-mayenne.jpg',
	fbnord=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/26b3d826-f907-4c0c-bdc9-08115c3d4152/sc_logo-nord.jpg',
	fbbassenormandie=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/4b1a9d2d-30d6-4dd7-aacf-a5679ddf65f7/sc_logo-normandie.jpg',
	fbhautenormandie=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/4b1a9d2d-30d6-4dd7-aacf-a5679ddf65f7/sc_logo-normandie.jpg',
	fbtoulouse=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/84e39c1c-1ade-430d-ba5e-a2cb35a76771/sc_logo-occitanie.jpg',
	fborleans=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/6ba4f915-c15b-4b75-bbff-00264c473c75/sc_logo-orleians.jpg',
	fbparis=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/aa396eeb-f9fa-4b9d-84fd-a56f2efeb296/sc_logo-paris.jpg',
	fbpaysbasque=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/0d62617b-681e-4232-a903-ecdd0a997f3b/sc_logo-pays-basque.jpg',
	fbpaysdauvergne=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/64d1fb99-9fd7-439b-a1b4-62697ea9e7ff/sc_logo-pays-dauvergne.jpg',
	fbpaysdesavoie=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/ef0c5a84-ac12-4f70-acd0-5f3b3ad2be4b/sc_logo-pays-de-savoie.jpg',
	fbperigord=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/b168c741-cd3c-442b-9e2a-bc2095bd4419/sc_logo-peirigord.jpg',
	fbpicardie=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/8e2f0a62-a424-4f47-aa94-0f1574b005ff/sc_logo-picardie.jpg',
	fbpoitou=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/2ef2cf02-387b-4bfb-8a92-87cde963efd9/sc_logo-poitou.jpg',
	fbprovence=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/2e36ab01-c5d5-4c20-9cc3-eebeb9c29d5b/sc_logo-provence.jpg',
	fbrcfm=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/3398334a-8666-4cb2-978a-4853ec7d2583/sc_logo-rvfm.jpg',
	fbroussillon=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/a735ac1b-f89f-471b-b3ee-551b6946c2e2/sc_logo-roussillon.jpg',
	fbsaintetienneloire=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/17f5ec94-e96a-442f-9bf8-6f8c3798605c/sc_logo-saint-etienne-loire.jpg',
	fbsudlorraine=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/d0448ffa-9420-4c1f-8fef-21e0d9f208ab/sc_logo-sud-lorraine.jpg',
	fbtouraine=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/8bb007f4-d458-4dad-a18c-1902679a5d9a/sc_logo-tourraine.jpg',
	fbvaucluse=> 'https://www.radiofrance.fr/s3/cruiser-production-eu3/2024/11/68c80936-8244-4806-bce2-52a17536fb56/sc_logo-vaucluse.jpg',

};

foreach my $metakey (keys(%$stationSet)){
	# Inialise the icons table - do not replace items that are already present (to allow override)
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising icons - $metakey");
	if ( not exists $icons->{$metakey} ){
		# Customise this if necessary per plugin
		$icons->{$metakey} = '';
	}
}


my $iconsIgnoreRegex = {
	fipradio => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipbordeaux => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipnantes => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipstrasbourg => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fiprock => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipjazz => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipgroove => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipmonde => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipnouveau => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipreggae => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipelectro => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipmetal => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fippop => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fiphiphop => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	fipsacre => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|fond_titres_diffuses_degrade.png|direct_default_cover_medium.png|_visual-fip.jpg)',
	mouv => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvxtra => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvclassics => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvdancehall => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvrnb => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvrapus => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvrapfr => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouv100mix => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
	mouvsansblabla => '(31d1838e-da34-4579-878b-0fb1027378b1|a0773022-c452-4206-9b16-76fe7147fec9|image_default_player.jpg)',
};

foreach my $metakey (keys(%$stationSet)){
	# Inialise the iconsIgnoreRegex table
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising iconsIgnoreRegex - $metakey");
	if ( not exists $iconsIgnoreRegex->{$metakey} ){
		# Customise this if necessary per plugin
		$iconsIgnoreRegex->{$metakey} = '(a0773022-c452-4206-9b16-76fe7147fec9|31d1838e-da34-4579-878b-0fb1027378b1)';
	}
}


# Uses match group 1 from regex call to try to find station
my %stationMatches = (
);

my $thisMatchStr = '';
foreach my $metakey (keys(%$stationSet)){
	# Inialise the stationMatches table - do not replace items that are already present (to allow override)
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising stationMatches - $metakey");
	foreach my $matchStr ('tuneinid', 'match1', 'match2'){
		if ( exists $stationSet->{$metakey}->{$matchStr} && $stationSet->{$metakey}->{$matchStr} ne ''){
			
			$thisMatchStr = $stationSet->{$metakey}->{$matchStr};
			
			if ($matchStr eq 'tuneinid') {
				# TuneIn id so special format needed
				$thisMatchStr = 'id='.$stationSet->{$metakey}->{$matchStr}.'&';
			}
			
			if ( not exists $stationMatches{$thisMatchStr} ){
				# main::DEBUGLOG && $log->is_debug && $log->debug("Adding to stationMatches - $thisMatchStr - $metakey");
				$stationMatches{$thisMatchStr} = $metakey;
			}
		}
	}
}

$dumped = Dumper \%stationMatches;
# print $dumped;
# main::DEBUGLOG && $log->is_debug && $log->debug("Initial stationMatches $dumped");


# $meta holds info about station that is playing - note - the structure is returned to others parts of LMS where particular field names are expected
# If you add fields to this then you probably will have to preserve it in parseContent
my $meta = {
    dummy => { title => '' },
};

foreach my $metakey (keys(%$stationSet)){
	# Inialise the meta table
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising meta - $metakey");
	$meta->{$metakey} = { busy => 0, title => $stationSet->{'fullname'}, icon => $icons->{$metakey}, cover => $icons->{$metakey}, ttl => 0, endTime => 0 },
}


# calculatedPlaying holds information about what is calculated as playing now
# Programme and Song data is held separately
my $calculatedPlaying = {
};

foreach my $metakey (keys(%$stationSet)){
	# Inialise the calculatedPlaying table
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising calculatedPlaying - $metakey");
	$calculatedPlaying->{$metakey} = { progtitle => '', progstart => 0, progend => 0, proglth => 0, proglogo => '', progsynopsis => '', progsubtitle => '', progid => '',
			  songtitle => '', songartist => '', songalbum => '', songstart => 0, songend => 0, songlth => 0, songcover => '', songlabel => '', songyear => '' };
}

# $coverFieldsArr contains the names of the fields from the source that hold the song cover / album art
# Ordered list with the highest priority (typical highest resolution) first

# Radio France cover, visual, coverUuid, visualBanner
# Extra varient to handle:
# [ { "name": "banner", "visual_uuid": "4256a1da-f202-4cfa-8c0b-db0fb846da66" },
#   { "name": "concept_visual", "visual_uuid": "aeb5db31-ea32-4149-8106-bc66c3ab26b7" } ]

my @coverFieldsArr = ( 'cover|src', 'cover', 'visual', 'xxxcoverUuid', 'visualBanner', 'cover_main', 'mainImage', 'cover_square', '@name|square_banner|visual_uuid',
					   '@name|banner|visual_uuid', '@name|concept_visual|visual_uuid', 'src', 'cardVisual|src', 'visuals|player|src' );


# $myClientInfo holds data about the clients/devices using this plugin - used to schedule next poll
my $myClientInfo = {};

# Customise this if necessary per plugin
# FIP via TuneIn
# http://opml.radiotime.com/Tune.ashx?id=s15200&formats=aac,ogg,mp3,wmpro,wma,wmvoice&partnerId=16
# Played via direct URL like ... http://direct.fipradio.fr/live/fip-midfi.mp3 which redirects to something with same suffix
# Match group 1 is used to find station id in %stationMatches - "fip-" last because it is a substring of others
# local variables used to help keep the lines shorter and easier to read
#my $tmpstr1 = 'fipbordeaux-|fipnantes-|fipstrasbourg-|fip-webradio1\.|fiprock-|fip-webradio2\.|fipjazz-|fip-webradio3\.|fipgroove-|fip-webradio4\.|fipworld-|fip-webradio5\.|';
#my $tmpstr2 = 'fipnouveautes-|fip-webradio6\.|fipreggae-|fip-webradio8\.|fipelectro-|fip-webradio7\.|fipmetal-|fip-|';
#my $tmpstr3 = 'francemusiqueeasyclassique-|francemusiqueclassiqueplus-|francemusiqueconcertsradiofrance-|francemusiquelajazz-|francemusiquelacontemporaine-|francemusiqueocoramonde-|francemusiquelevenementielle-|';
#my $tmpstr4 = 'mouv-|mouvxtra-|mouvclassics-|mouvdancehall-|mouvrnb-|mouvrapus-|mouvrapfr-|mouv100p100mix-|franceinter-';
#my $tmpstr1 = '';
my $tmpstr1 = '';
foreach my $metakey (keys(%$stationSet)){
	if ( exists $stationSet->{$metakey}->{'match1'} && $stationSet->{$metakey}->{'match1'} ne '' &&
	     $stationSet->{$metakey}->{'notexcludable'} ){
		# match1 given so add it in (if not already there)
		if ( $tmpstr1 ne '' ) { $tmpstr1 .='|';	}	# Add in an OR divider if was not empty so that list is built correctly
		$tmpstr1 .= $stationSet->{$metakey}->{'match1'};
	}
}

#Add in 2nd set ... could be for a 2nd match set or for items that need to be after the first set for the matching logic to work
foreach my $metakey (keys(%$stationSet)){
	if ( exists $stationSet->{$metakey}->{'match2'} && $stationSet->{$metakey}->{'match2'} ne '' &&
	     $stationSet->{$metakey}->{'notexcludable'} ){
		# match2 given so add it in (if not already there)
		if ( $tmpstr1 ne '' ) { $tmpstr1 .='|';	}	# Add in an OR divider if was not empty so that list is built correctly
		$tmpstr1 .= $stationSet->{$metakey}->{'match2'};
	}
}
# main::DEBUGLOG && $log->is_debug && $log->debug("Constructed match2 string1 $tmpstr1");
# If extras are required then put them in here (start with |)
my $tmpstr2 = '';
my $tmpstr3 = '';
my $tmpstr4 = '';

my $tmptunein1 = '';
foreach my $metakey (keys(%$stationSet)){
	if ( exists $stationSet->{$metakey}->{'tuneinid'} && $stationSet->{$metakey}->{'tuneinid'} ne '' &&
	     $stationSet->{$metakey}->{'notexcludable'} ){
		# match1 given so add it in (if not already there)
		if ( $tmptunein1 ne '' ) { $tmptunein1 .='|';	}	# Add in an OR divider if was not empty so that list is built correctly
		$tmptunein1 .= 'id='.$stationSet->{$metakey}->{'tuneinid'}.'&';
	}
}
# main::DEBUGLOG && $log->is_debug && $log->debug("Constructed tunein1 string1 $tmptunein1");
# If extras are required then put them in here (start with |)
my $tmptunein2 = '';
my $tmptunein3 = '';
my $tmptunein4 = '';

# Example stream URLs
# https://icecast.radiofrance.fr/fip-midfi.mp3
# https://stream.radiofrance.fr/fip/fip.m3u8
# hlsplays://stream.radiofrance.fr/fip/fip_hifi.m3u8 (special PlayHLS)

my @urlRegexSet = ( qr/(?:\/)($tmpstr1$tmpstr2$tmpstr3$tmpstr4)[_\-.](?:midfi|lofi|hifi|)/i,
# Selected via TuneIn base|bordeaux|nantes|strasbourg|rock|jazz|groove|monde|nouveau|reggae|electro|metal FranceMusique - ClassicEasy|ClassicPlus|Concerts|Contemporaine|OcoraMonde|ClassiqueKids/Evenementielle/B.O. - Mouv|classics|dancehall|rnb|rapus|rapfr|100mix
					# qr/(?:radiotime|tunein)\.com.*(id=s15200&|id=s50706&|id=s50770&|id=s111944&|id=s262528&|id=s262533&|id=s262537&|id=s262538&|id=s262540&|id=s293090&|id=s293089&|id=s308366&|id=s283174&|id=s283175&|id=s283176&|id=s283178&|id=s283179&|id=s283177&|id=s285660|id=s306575&|id=s6597&|id=s244069&|id=s307693&|id=s307694&|id=s307695&|id=s307696&|id=s307697&)/i,
					qr/(?:radiotime|tunein)\.com.*($tmptunein1$tmptunein2$tmptunein3$tmptunein4)/i,
);
# 2nd set is for non-song-based stations so that they can be optionally disabled
$tmpstr1 = '';
foreach my $metakey (keys(%$stationSet)){
	if ( exists $stationSet->{$metakey}->{'match1'} && $stationSet->{$metakey}->{'match1'} ne '' &&
	     ( (not exists $stationSet->{$metakey}->{'notexcludable'}) || $stationSet->{$metakey}->{'notexcludable'} == false )){
		# match1 given so add it in (if not already there)
		if ( $tmpstr1 ne '' ) { $tmpstr1 .='|';	}	# Add in an OR divider if was not empty so that list is built correctly
		$tmpstr1 .= $stationSet->{$metakey}->{'match1'};
	}
}
# main::DEBUGLOG && $log->is_debug && $log->debug("Constructed excludable match2 string1 $tmpstr1");
# If extras are required then put them in here (start with |)
$tmpstr2 = '';
$tmpstr3 = '';
$tmpstr4 = '';

# Add in 2nd set ... could be for a 2nd match set or for items that need to be after the first set for the matching logic to work
foreach my $metakey (keys(%$stationSet)){
	if ( exists $stationSet->{$metakey}->{'match2'} && $stationSet->{$metakey}->{'match2'} ne '' &&
	     ( (not exists $stationSet->{$metakey}->{'notexcludable'}) || $stationSet->{$metakey}->{'notexcludable'} == false )){
		# match1 given so add it in (if not already there)
		if ( $tmpstr1 ne '' ) { $tmpstr1 .='|';	}	# Add in an OR divider if was not empty so that list is built correctly
		$tmpstr1 .= $stationSet->{$metakey}->{'match2'};
	}
}

$tmptunein1 = '';
foreach my $metakey (keys(%$stationSet)){
	if ( exists $stationSet->{$metakey}->{'tuneinid'} && $stationSet->{$metakey}->{'tuneinid'} ne '' &&
	     ( (not exists $stationSet->{$metakey}->{'notexcludable'}) || $stationSet->{$metakey}->{'notexcludable'} == false )){
		# match1 given so add it in (if not already there)
		if ( $tmptunein1 ne '' ) { $tmptunein1 .='|';	}	# Add in an OR divider if was not empty so that list is built correctly
		$tmptunein1 .= 'id='.$stationSet->{$metakey}->{'tuneinid'}.'&';
	}
}
# main::DEBUGLOG && $log->is_debug && $log->debug("Constructed excludable tunein1 string1 $tmptunein1");
# If extras are required then put them in here (start with |)
$tmptunein2 = '';
$tmptunein3 = '';
$tmptunein4 = '';

my @urlRegexNonSongSet = ( #qr/(?:\/)(franceinter-|franceinfo-|francemusique-|franceculture-)(?:midfi|lofi|hifi|)/i,
			    qr/(?:\/)($tmpstr1$tmpstr2$tmpstr3$tmpstr4)[_\-.](?:midfi|lofi|hifi|)/i,
							# Selected via TuneIn franceinter|franceinfo|francemusique|franceculture
			   #qr/(?:radiotime|tunein)\.com.*(id=s24875&|id=s9948&|id=s15198&|id=s2442&)/i,
			   qr/(?:radiotime|tunein)\.com.*($tmptunein1$tmptunein2$tmptunein3$tmptunein4)/i,
);

sub getDisplayName {
	return 'PLUGIN_RADIOFRANCE';
}

sub playerMenu { shift->can('nonSNApps') && $prefs->get('is_app') ? undef : 'RADIO' }

sub getLocalAdjustedTime {
	# Get the local time - but adjust it for estimated stream delay
	my $adjustedTime;
	# Using HiRes time because of difference with ordinary time when running on MacOS
	$adjustedTime = int(Time::HiRes::time())-$prefs->get('streamdelay');

	return $adjustedTime;
}

sub initPlugin {
	my $class = shift;
	
	$VERSION = $class->_pluginDataFor('version');

	$prefs->init({ disablealbumname => 0 });
	$prefs->init({ showprogimage => 0 });
	$prefs->init({ appendlabel => 0 });
	$prefs->init({ appendyear => 0 });
	$prefs->init({ hidetrackduration => 0 });
	$prefs->init({ streamdelay => 2 });	# Assume that stream is 2 seconds behind real-time
	$prefs->init({ excludesomestations => 0});
	$prefs->init({ excludesynopsis => 0});
	$prefs->init({ menulocation => 1});	# 0=No, 1=Radio, 2=My Apps
	$prefs->init({ schedulenumofdays => 8});
	$prefs->init({ hidenoaudio => 1});
	$prefs->init({ scheduledayname => 1});	# 0=None, 1=Short, 2=Long
	$prefs->init({ scheduleflatten => 0});	# Flatten the schedule (show segments like programmes)
	$prefs->init({ schedulecachetimer => 10});	# 10 minute cache

	if ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		# Warn if HTTPS support not present because some of the meta provider URLs redirect to https (since February 2018)
		$log->error(string('PLUGIN_RADIOFRANCE_MISSING_SSL'));
	}

	foreach my $urlRegex (@urlRegexSet) {
		# Loop through the regex set and register them as Parser and Provider
		if ($urlRegex ne ''){
			Slim::Formats::RemoteMetadata->registerParser(
				match => $urlRegex,
				func  => \&parser,
			);
		
			Slim::Formats::RemoteMetadata->registerProvider(
				match => $urlRegex,
				func  => \&provider,
			);
		}
	}

	if (!$prefs->get('excludesomestations')){
		foreach my $urlRegex (@urlRegexNonSongSet) {
			# Loop through the regex set and register them as Parser and Provider
			if ($urlRegex ne ''){
				Slim::Formats::RemoteMetadata->registerParser(
					match => $urlRegex,
					func  => \&parser,
				);
			
				Slim::Formats::RemoteMetadata->registerProvider(
					match => $urlRegex,
					func  => \&provider,
				);
			}
		}
	}
	
	if ( $prefs->get('menulocation') > 0 ) {
	
		my $file = catdir( $class->_pluginDataFor('basedir'), 'menu.opml' );
			
		$class->SUPER::initPlugin(
			#feed   => Slim::Utils::Misc::fileURLFromPath($file),
			feed   => \&Plugins::RadioFrance::Plugin::toplevel,
			tag    => $pluginName,
			is_app => $class->can('nonSNApps') && ($prefs->get('menulocation') == 2) ? 1 : undef,
			menu   => 'radios',
			weight => 1,
		);
	};
	
	Plugins::RadioFrance::Settings->new;
}

sub _pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		return $pluginData->{$key};
	}

	return undef;
}


sub parser {
	my ( $client, $url, $metadata ) = @_;
	
	my ( $artist, $title, $thismeta );
	
	main::DEBUGLOG && $log->is_debug && $log->debug("parser - for client ".$client->name." Been called to parse data: $metadata with URL $url");
	
	# Get the current preferences just in case they were changed recently
	$prefs = preferences('plugin.'.$pluginName);
	
	if ($url ne '') {
		
		my $station = &matchStation( $url );

		if ($station ne ''){
			# Call getmeta to get the data from radio station ... which will also put itself onto timer for subsequent fetches
			$thismeta = &getmeta( $client, $url, false );
			
			# main::DEBUGLOG && $log->is_debug && $log->debug("Returned from getmeta");

			return 1;
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug("No metadata set for $url");
			return 0;
		}
	}
	
	main::DEBUGLOG && $log->is_debug && $log->debug("No metadata set for $url");
	
	return 0;
}


sub matchStation {

	my $url = shift;
	
	my $testUrl = $url;
	
	# Which station? (Return empty if nothing matched - this could happen if match happens by mistake
	my $station = '';

	# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 1 received for $url");
	foreach my $urlRegex (@urlRegexSet){
		# main::DEBUGLOG && $log->is_debug && $log->debug("Checking against $urlRegex");
		
		$testUrl = lc($url);
		if ($testUrl =~ $urlRegex) {
			# $1 contains the capture ... assuming one was defined in the regex ... which it should be in our case
			if (defined($1)) {$testUrl = $1};
		}
		
		# main::DEBUGLOG && $log->is_debug && $log->debug("Try $testUrl");
		
		if ($testUrl && exists $stationMatches{$testUrl}) {
			# Found a match so take this station
			$station = $stationMatches{$testUrl};
			# main::DEBUGLOG && $log->is_debug && $log->debug("matchStation - Found $station via urlRegexSet");
			last;	# Found it
		} else {
			# Check against the list of broadcaster ids (this check is for stations that are not in the excludable set)
			foreach my $stationkey (keys(%$stationSet)){
				# main::DEBUGLOG && $log->is_debug && $log->debug("matchStation - checking $stationkey in stationSet");
				if ( ref($stationSet->{$stationkey}) eq "HASH" &&
				     exists $stationSet->{$stationkey}->{notexcludable} && $stationSet->{$stationkey}->{notexcludable} &&
				     exists $stationSet->{$stationkey}->{extramatch} && $stationSet->{$stationkey}->{extramatch} eq $testUrl ) {
					$station = $stationkey;
					main::DEBUGLOG && $log->is_debug && $log->debug("matchStation - Found $station in stationSet");
					last;	# Found it
				}
			}
		}
		
		last if $station ne '';
	}

	if ($station eq '' && !$prefs->get('excludesomestations')){
		# Not found yet - so try the other sets
		# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 4 received for $url");
		$testUrl = $url;
		
		foreach my $urlRegex (@urlRegexNonSongSet){
			# main::DEBUGLOG && $log->is_debug && $log->debug("Checking against $urlRegex");
			
			$testUrl = lc($url);
			if ($testUrl =~ $urlRegex) {
				# $1 contains the capture ... assuming one was defined in the regex ... which it should be in our case
				if (defined($1)) {$testUrl = $1};
			}
			
			# main::DEBUGLOG && $log->is_debug && $log->debug("Try $1");
			
			if ($testUrl && exists $stationMatches{$testUrl}) {
				# Found a match so take this station
				$station = $stationMatches{$testUrl};
				# main::DEBUGLOG && $log->is_debug && $log->debug("matchStation - Found $station via urlRegexNonSongSet");
				last;	# Found it
			} else {
				# Check against the list of broadcaster ids (this check is for all stations including those are in the excludable set)
				foreach my $stationkey (keys(%$stationSet)){
					# main::DEBUGLOG && $log->is_debug && $log->debug("matchStation - checking $stationkey in stationSet");
					if ( ref($stationSet->{$stationkey}) eq "HASH" &&
					     exists $stationSet->{$stationkey}->{extramatch} && $stationSet->{$stationkey}->{extramatch} eq $testUrl ) {
						$station = $stationkey;
						main::DEBUGLOG && $log->is_debug && $log->debug("matchStation - Found $station in full stationSet");
						last;	# Found it
					}
				}
			}
			
			last if $station ne '';
		}
	}

	if ($station eq ''){
		# Match not made - so log it
		main::INFOLOG && $log->is_info && $log->info("matchStation failed to match $url");
	}

	# main::DEBUGLOG && $log->is_debug && $log->debug("matchStation matched $station");
	
	return $station;
}


sub provider {

	my ( $client, $url ) = @_;
	# This tiny routine is to help tracing / debugging - it should only be called through the provider registration
	# Internal calls go direct to getmeta to help spot the difference between a timer expiry and LMS core call
	# main::DEBUGLOG && $log->is_debug && $log->debug("provider - device ".$client->name." called with URL ".$url);
	
	return &getmeta( $client, $url, true );
}


sub getcover {
	my ( $playinginfo, $station, $info ) = @_;
	
	my $thisartwork = '';
	my $suffix = '';
	
	#$dumped = Dumper $playinginfo;
	#main::DEBUGLOG && $log->is_debug && $log->debug("$station - getcover - checking $dumped");

	foreach my $fieldName ( @coverFieldsArr ) {
		# Loop through the list of field names and take first (if any) match
		
		# Check for special syntax for subfield
		my ($field1, $field2, $field3) = split('\|', $fieldName, 3);

		if ( !defined $field2 ){
			if ( ref($playinginfo) ne "ARRAY" && exists $playinginfo->{$field1} && defined($playinginfo->{$field1}) && $playinginfo->{$field1} ne '' ){
				$thisartwork = $playinginfo->{$field1};
				last;
			}
		} elsif ( !defined $field3 ) {
			if ( ref($playinginfo) ne "ARRAY" && exists $playinginfo->{$field1} && defined($playinginfo->{$field1}) && $playinginfo->{$field1} ne '' && 
			     ref($playinginfo->{$field1}) eq 'HASH' && exists $playinginfo->{$field1}->{$field2} && defined($playinginfo->{$field1}->{$field2}) && ref($playinginfo->{$field1}->{$field2}) ne 'HASH' && 
				 $playinginfo->{$field1}->{$field2} ne ''){
				$thisartwork = $playinginfo->{$field1}->{$field2};
				last;
			}
		} else {
			if ( ref($playinginfo) eq "ARRAY" && substr( $field1,0,1 ) eq '@'){
				# An expected array so loop through
				my $fieldX = substr( $field1,1 );
				foreach my $thisrow ( @$playinginfo ){
					if ( exists $thisrow->{$fieldX} && defined($thisrow->{$fieldX}) && $thisrow->{$fieldX} ne '' && 
					     $thisrow->{$fieldX} eq $field2 &&
					     exists $thisrow->{$field3} && defined($thisrow->{$field3}) && $thisrow->{$field3} ne ''){
						$thisartwork = $thisrow->{$field3};
						last;
					}
				}
				
				if ($thisartwork ne '' ){
					last;
				}
			} else {
				if ( ref($playinginfo) eq "HASH" && exists $playinginfo->{$field1} && 
				     ref($playinginfo->{$field1}) eq "HASH" && defined($playinginfo->{$field1}) && $playinginfo->{$field1} ne '' &&
				     # $playinginfo->{$field1} eq $field2 &&
					 exists $playinginfo->{$field1}->{$field2} && defined($playinginfo->{$field1}->{$field2}) && 
					 ref($playinginfo->{$field1}->{$field2}) eq 'HASH' && $playinginfo->{$field1}->{$field2} ne '' &&
				     exists $playinginfo->{$field1}->{$field2}->{$field3} && defined($playinginfo->{$field1}->{$field2}->{$field3}) && 
					 ref($playinginfo->{$field1}->{$field2}->{$field3}) ne 'HASH' && $playinginfo->{$field1}->{$field2}->{$field3} ne ''){
					$thisartwork = $playinginfo->{$field1}->{$field2}->{$field3};
					
					if ( $thisartwork !~ /\.(?:jpe?g|gif|png)/i && exists $playinginfo->{$field1}->{$field2}->{'preset'} && $playinginfo->{$field1}->{$field2}->{'preset'} eq 'raw' ){
						$suffix = '/'.$playinginfo->{$field1}->{$field2}->{'preset'};
					}
					last;
				}
			}
		}
	}
	
	$thisartwork .= $suffix;

	# Now check to see if there are any size issues and replace if possible
	# Note - this uses attributes found in ABC Australia data so would need changing for other sources
	if ( ref($playinginfo) ne "ARRAY" && exists $playinginfo->{width} && defined($playinginfo->{width}) &&
	     exists $playinginfo->{height} && defined($playinginfo->{height}) &&
	     ($playinginfo->{width} > maxImgWidth || $playinginfo->{height} > maxImgHeight) ){
		# Default image is too big so try for another one
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - getcover - image too big");
		
		if ( exists $playinginfo->{sizes} && ref($playinginfo->{sizes}) eq "ARRAY" ){
			# Array of sizes given so loop through trying to find the largest inside the limit
			my @images = @{ $playinginfo->{sizes} };
			
			# Set to minimum that willing to accept
			my $bestFitWidth = 64;
			my $bestFitHeight = 64;
			my $bestFitArtwork = '';
			
			foreach my $thisImage ( @images ) {
				if ( exists $thisImage->{width} && defined($thisImage->{width}) &&
				     exists $thisImage->{height} && defined($thisImage->{height}) &&
				     ($thisImage->{width} <= maxImgWidth && $thisImage->{height} <= maxImgHeight) ){
					# Candidate ... see if bigger than one we already have (if any)
					if ( $thisImage->{width} > $bestFitWidth && $thisImage->{height} > $bestFitHeight ){
						# Take it (for now)
						$bestFitWidth = $thisImage->{width};
						$bestFitHeight = $thisImage->{height};
						foreach my $fieldName ( @coverFieldsArr ) {
							# Loop through the list of field names and take first (if any) match
							if ( exists $thisImage->{$fieldName} && defined($thisImage->{$fieldName}) && $thisImage->{$fieldName} ne '' ){
								$bestFitArtwork = $thisImage->{$fieldName};
								last;
							}
						}
					}
				}
			}
			
			if ( $bestFitArtwork ne '' ){
				# Found one
				$thisartwork = $bestFitArtwork;
				# main::DEBUGLOG && $log->is_debug && $log->debug("$station - getcover - replaced with smaller image ($bestFitWidth x $bestFitHeight) $thisartwork");
			}
		}
	}

	if ( $thisartwork =~ m/\{.*\}/ ){
		# Keyword replacement
		$thisartwork =~ s/\$?\{width\}/${\maxImgWidth}/g;
		$thisartwork =~ s/\$?\{ratio\}/1x1/g;
	}

	if ( $thisartwork ne ''){
		if ( exists($iconsIgnoreRegex->{$station}) && $iconsIgnoreRegex->{$station} ne '' && $thisartwork =~ /$iconsIgnoreRegex->{$station}/ ) {
			# main::DEBUGLOG && $log->is_debug && $log->debug("getcover - Removing1 $thisartwork");
			$thisartwork = '';
		}
	}

	if ( $thisartwork ne ''){
		if ($info ne '' && $thisartwork eq $info->{icon}) {
			# main::DEBUGLOG && $log->is_debug && $log->debug("getcover - Removing2 $thisartwork");
			$thisartwork = '';
		}
	}

	if ( $thisartwork ne ''){
		if ( $thisartwork !~ /^https?:/i && $thisartwork =~ /^.*-.*-.*-.*-/ ) {
			# main::DEBUGLOG && $log->is_debug && $log->debug("getcover - Replacing $thisartwork");
			my $rewriteart = true;
			if ( $station && exists $stationSet->{$station}->{'artfromuid'} && defined($stationSet->{$station}->{'artfromuid'}) ){
				$rewriteart = $stationSet->{$station}->{'artfromuid'};
			}

			if ( $rewriteart ){
				$thisartwork = $imageapiprefix.$thisartwork.$imageapisuffix;
			} else {
				$thisartwork = '';
			}
		}
	}


	# if (($thisartwork ne '' && ($thisartwork !~ /$iconsIgnoreRegex->{$station}/ || ($info ne '' && $thisartwork eq $info->{icon}))) &&
	     # ($thisartwork =~ /^https?:/i) || $thisartwork =~ /^.*-.*-.*-.*-/){
	     # # There is something, it is not excluded, it is not the station logo and (it appears to be a URL or an id)
	     # # example id "visual": "38fab9df-91cc-4e50-adc4-eb3a9f2a017a",
		# if ($thisartwork =~ /^.*-.*-.*-.*-/ && $thisartwork !~ /^https?:/i){
			# #main::DEBUGLOG && $log->is_debug && $log->debug("$station - image id $thisartwork");
			# my $rewriteart = true;
			# if ( $station && exists $stationSet->{$station}->{'artfromuid'} && defined($stationSet->{$station}->{'artfromuid'}) ){
				# $rewriteart = $stationSet->{$station}->{'artfromuid'};
			# }

			# if ( $rewriteart ){
				# $thisartwork = $imageapiprefix.$thisartwork.$imageapisuffix;
			# } else {
				# $thisartwork = '';
			# }
		# }
		
	# } else {
		# # Icon not present or matches one to be ignored
		# # main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$playinginfo->{'visual'});
		# $thisartwork = '';
	# }
	
	#main::DEBUGLOG && $log->is_debug && $log->debug("$station - getcover - returning: $thisartwork");
	
	return $thisartwork;
}


sub getmeta {
	
	my ( $client, $url, $fromProvider) = @_;
	
	$prefs = preferences('plugin.'.$pluginName);
	
	my $deviceName = "";

	my $station = &matchStation( $url );
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Timer return - no device name");
	} else {
		$deviceName = $client->name;
	};
	

	if ($station ne ''){
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - IsPlaying=".$client->isPlaying." getmeta called with URL $url");

		my $hiResTime = getLocalAdjustedTime;
		
		# don't query the remote meta data every time we're called
		if ( $client->isPlaying && (!$meta->{$station} || $meta->{$station}->{ttl} <= $hiResTime) &&
		     !$meta->{$station}->{busy} && $urls->{$station} ne '' ) {
			
			$meta->{$station}->{busy} = $meta->{$station}->{busy}+1;

			my $http = Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$meta->{ $station } = parseContent($client, shift->content, $station, $url);
				},
				sub {
					# in case of an error, don't try too hard...
					$meta->{ $station } = parseContent($client, '', $station, $url);
				},
			);
			
			my $sourceUrl = $urls->{$station};
			
			if ( $sourceUrl =~ /\$\{.*\}/ ){
				# Special string to be replaced
				$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
				$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
				$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
				$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
				$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
			}
			
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching data from $sourceUrl");
			$http->get($sourceUrl);
			
			if (exists $urls->{$station."_alt"} && $urls->{$station."_alt"} ne ''){
				# If there is an alternate URL - do an additional fetch for it
				
				my $httpalt = Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						$meta->{ $station } = parseContent($client, shift->content, $station, $url);
					},
					sub {
						# in case of an error, don't try too hard...
						$meta->{ $station } = parseContent($client, '', $station, $url);
					},
				);
			
				$sourceUrl = ($urls->{$station."_alt"});
				
				if ( $sourceUrl =~ /\$\{.*\}/ ){
					# Special string to be replaced
					$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
					$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
					$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
					$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
					$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
				}
				
				$meta->{$station}->{busy} = $meta->{$station}->{busy}+1;	# Increment busy counter - might be possible that the one above already finished so increment rather than set to 2
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching alternate data from $sourceUrl");
				$httpalt->get($sourceUrl);
			}

		} elsif ( $urls->{$station} eq '' ){
			# No song info URL ... so maybe needs to be kicked off with a programme fetch
			&getprogrammemeta( $client, $url, false, $progListPerStation );
		}

		# Get information about what this device is playing
		my $controller = $client->controller()->songStreamController();
		my $song = $controller->song() if $controller;
		
		if ($song){
			# Found something - so see if there is meta data
			if ( my $playingsong = $client->playingSong() ) {
				if ( my $playingmeta = $playingsong->pluginData('wmaMeta') ) {

					my $playinginfo = "";
					
					if ( $playingmeta->{artist} ) {
						$playinginfo .= $playingmeta->{artist}.' - ';
					}
					if ( $playingmeta->{title} ) {
						$playinginfo .= $playingmeta->{title};
					}
					if ( $playingmeta->{album} ) {
						$playinginfo .= ' from: '.$playingmeta->{album};
					}
					if ( $playingmeta->{cover} ) {
						$playinginfo .= ' cover: '.$playingmeta->{cover};
					}
				}
			}
			
			# This is to get around the problem when 2 unsynced devices are playing the same station
			# updateClient checks to see what we sent before and only sends if different now
			# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - About to force ");
			&updateClient( $client, $song, $meta->{$station}, $hiResTime );
			
			# Just in case - make sure that there is a timer running
			&deviceTimer( $client, $meta->{ $station }, $url );
		}
		
		return $meta->{$station};

	} else {
		# Station not found
		main::INFOLOG && $log->is_info && $log->info("provider not found station for URL $url");
		return $meta->{'dummy'}
	}
}


sub getindividualprogrammemeta {
	
	my ( $client, $url, $progpath ) = @_;
	
	$prefs = preferences('plugin.'.$pluginName);

	my $whenFetchedKey = 'individualprog';
	my $deviceName = "";

	my $station = &matchStation( $url );
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - getindividualprogrammemeta - no device name");
	} else {
		$deviceName = $client->name;
	};

	if ($station ne '' && 
	    (( exists $urls->{$pluginName.'progdata'} && $urls->{$pluginName.'progdata'} ne '') ||
	    (exists $stationSet->{$station}->{'individualprogurl'} && 
	    ( ref $stationSet->{$station}->{'individualprogurl'} eq "ARRAY" || $stationSet->{$station}->{'individualprogurl'} ne '' ) ) ) ){
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - IsPlaying=".$client->isPlaying." called with URL $url");

		my $hiResTime = getLocalAdjustedTime;

		if ( not exists $programmeMeta->{'whenfetched'}->{$whenFetchedKey} ){
			$programmeMeta->{'whenfetched'}->{$whenFetchedKey} = '';
		}
		
		my @urlsarr;
		
		my $tmpsongurl = $stationSet->{$station}->{'individualprogurl'};
		
		#main::DEBUGLOG && $log->is_debug && $log->debug("$station - songurl - $tmpsongurl") if $tmpsongurl;

		# Do not use songurl if single and does not start http - allows station override of fetch
		if ( $tmpsongurl && ( ref $tmpsongurl eq 'ARRAY' || $tmpsongurl =~ /^http/i ) ){
			if ( ref $tmpsongurl eq 'ARRAY' ){
				push @urlsarr, @$tmpsongurl;
			} else {
				push @urlsarr, $tmpsongurl;
			}
		}
		
		if ( $client->isPlaying && ($programmeMeta->{'whenfetched'}->{$whenFetchedKey} eq '' || $programmeMeta->{'whenfetched'}->{$whenFetchedKey} <= $hiResTime - 30)) {
			
			$programmeMeta->{'whenfetched'}->{$whenFetchedKey} = $hiResTime;	# Say we have fetched it now - even if it fails

			my $loopCnt = -1;
			
			for my $loopUrl ( @urlsarr ){
				
				my $sourceUrl = $loopUrl;
				
				$loopCnt++;

				my $http = Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						$meta->{ $station } = parseContent($client, shift->content, $station, $url);
					},
					sub {
						# in case of an error, don't try too hard...
						$meta->{ $station } = parseContent($client, '', $station, $url);
					},
				);
				
				# if ( exists $stationSet->{$station}->{'individualprogurl'} && $stationSet->{$station}->{'individualprogurl'} ne ''){
					# $sourceUrl = $stationSet->{$station}->{'individualprogurl'};
				# }

				if ( $sourceUrl =~ /\$\{.*\}/ ){
					# Special string to be replaced
					$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
					$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
					$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
					$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
					$sourceUrl =~ s/\$\{progstart\}/$calculatedPlaying->{$station}->{'progstart'}/g;
					$sourceUrl =~ s/\$\{progend\}/$calculatedPlaying->{$station}->{'progend'}/g;
					$sourceUrl =~ s/\$\{progpath\}/$progpath/g;
					$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
				}
				
				if ( $sourceUrl =~ /\$\{.*\}/ ){
					# Something did not convert - so do not use
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - not risking $sourceUrl");
				} else {
					my %headers = ();
					 
					if ( exists $stationSet->{$station}->{'progheaders'} && $stationSet->{$station}->{'progheaders'} ne ''){
						%headers = %{ $stationSet->{$station}->{'progheaders'} };
					}				
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching programme data from $sourceUrl");
					$http->get($sourceUrl, %headers);
				}
			}	# end loop
		}

		# No need to set up a timer for this as the song fetch will trigger a new one if needed
		return $meta->{$station};

	} else {
		# Not fatal since might not have been configured
		# main::INFOLOG && $log->is_info && $log->info("progdata provider not found $station for URL $url");
		return $meta->{'dummy'}
	}
}



sub getprogrammemeta {
	
	my ( $client, $url, $fromProvider, $perStation ) = @_;
	
	$prefs = preferences('plugin.'.$pluginName);

	my $whenFetchedKey = 'allservices';
	my $deviceName = "";

	my $station = &matchStation( $url );
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - getprogrammemeta - no device name");
	} else {
		$deviceName = $client->name;
	};

	if ($station ne '' && 
	    (( exists $urls->{$pluginName.'progdata'} && $urls->{$pluginName.'progdata'} ne '') ||
	    (exists $stationSet->{$station}->{'scheduleurl'} && $stationSet->{$station}->{'scheduleurl'} ne '') ) ){
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - IsPlaying=".$client->isPlaying." called with URL $url");

		my $hiResTime = getLocalAdjustedTime;
		
		# don't query the remote meta data every time we're called
		if ( $perStation ) { $whenFetchedKey = $station; }

		if ( not exists $programmeMeta->{'whenfetched'}->{$whenFetchedKey} ){
			$programmeMeta->{'whenfetched'}->{$whenFetchedKey} = '';
		}
		
		
		if ( $client->isPlaying && ($programmeMeta->{'whenfetched'}->{$whenFetchedKey} eq '' || $programmeMeta->{'whenfetched'}->{$whenFetchedKey} <= $hiResTime - 600)) {
			
			$programmeMeta->{'whenfetched'}->{$whenFetchedKey} = $hiResTime;	# Say we have fetched it now - even if it fails

			my $http = Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$meta->{ $station } = parseContent($client, shift->content, $station, $url);
				},
				sub {
					# in case of an error, don't try too hard...
					$meta->{ $station } = parseContent($client, '', $station, $url);
				},
			);
			
			my $sourceUrl = '';
			
			if ( exists $stationSet->{$station}->{'scheduleurl'} && $stationSet->{$station}->{'scheduleurl'} ne ''){
				$sourceUrl = $stationSet->{$station}->{'scheduleurl'};
			} else {
				$sourceUrl = $urls->{$pluginName.'progdata'};
			}

			if ( $sourceUrl =~ /\$\{.*\}/ ){
				# Special string to be replaced
				$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
				$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
				$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
				$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
				$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
			}
			
			my %headers = ();
			 
			if ( exists $stationSet->{$station}->{'progheaders'} && $stationSet->{$station}->{'progheaders'} ne ''){
				%headers = %{ $stationSet->{$station}->{'progheaders'} };
			}				
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching programme data from $sourceUrl");
			$http->get($sourceUrl, %headers);
			
			if (exists $urls->{$pluginName.'progdata'."_alt"} && $urls->{$pluginName.'progdata'."_alt"} ne ''){
				# If there is an alternate URL - do an additional fetch for it
				
				
				my $httpalt = Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						$meta->{ $station } = parseContent($client, shift->content, $station, $url);
					},
					sub {
						# in case of an error, don't try too hard...
						$meta->{ $station } = parseContent($client, '', $station, $url);
					},
				);
			
				$sourceUrl = ($urls->{$pluginName.'progdata'."_alt"});
				
				if ( $sourceUrl =~ /\$\{.*\}/ ){
					$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
					$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
					$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
					$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
					$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
				}

				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching alternate programme data from $sourceUrl");
				$httpalt->get($sourceUrl);
			}

		}

		# No need to set up a timer for this as the song fetch will trigger a new one if needed
		return $meta->{$station};

	} else {
		# Not fatal since might not have been configured
		# main::INFOLOG && $log->is_info && $log->info("progdata provider not found $station for URL $url");
		return $meta->{'dummy'}
	}
}


sub getbroadcastermeta {
	
	my ( $client, $url, $fromProvider) = @_;
	
	$prefs = preferences('plugin.'.$pluginName);
	
	my $deviceName = "";

	my $station = &matchStation( $url );
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - getbroadcastermeta - no device name");
	} else {
		$deviceName = $client->name;
	};
	

	if ($station ne '' && exists $urls->{$pluginName.'broadcasterdata'} && $urls->{$pluginName.'broadcasterdata'} ne ''){
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - IsPlaying=".$client->isPlaying." getbroadcastermeta called with URL $url");

		my $hiResTime = getLocalAdjustedTime;
		
		# don't query the remote meta data every time we're called
		if ( $client->isPlaying && ($programmeMeta->{'whenfetchedbroadcaster'} eq '' || $programmeMeta->{'whenfetchedbroadcaster'} <= $hiResTime - (24*60*60))) {
			
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Broadcaster data last fetched $programmeMeta->{'whenfetchedbroadcaster'}");
			
			$programmeMeta->{'whenfetchedbroadcaster'} = $hiResTime;	# Say we have fetched it now - even if it fails

			my $http = Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$meta->{ $station } = parseContent($client, shift->content, $station, $url);
				},
				sub {
					# in case of an error, don't try too hard...
					$meta->{ $station } = parseContent($client, '', $station, $url);
				},
			);
			
			my $sourceUrl = $urls->{$pluginName.'broadcasterdata'};
			
			if ( $sourceUrl =~ /\$\{.*\}/ ){
				# Special string to be replaced
				$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
				$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
				$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
				$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
			}
			
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching broadcaster data from $sourceUrl");
			$http->get($sourceUrl);
			
			if (exists $urls->{$pluginName.'broadcasterdata'."_alt"}){
				# If there is an alternate URL - do an additional fetch for it
				
				my $httpalt = Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						$meta->{ $station } = parseContent($client, shift->content, $station, $url);
					},
					sub {
						# in case of an error, don't try too hard...
						$meta->{ $station } = parseContent($client, '', $station, $url);
					},
				);
			
				$sourceUrl = ($urls->{$pluginName.'broadcasterdata'."_alt"});
				
				if ( $sourceUrl =~ /\$\{.*\}/ ){
					# Special string to be replaced
					$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
					$sourceUrl =~ s/\$\{fetchid\}/$stationSet->{$station}->{'fetchid'}/g;
					$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
					$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
				}
				
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching alternate broadcaster data from $sourceUrl");
				$httpalt->get($sourceUrl);
			}

		}

		# No need to set up a timer for this as the song fetch will trigger a new one if needed
		return $meta->{$station};

	} else {
		# Station not found - or not configured
		if ($station eq '' ){
			main::INFOLOG && $log->is_info && $log->info("provider not found station for URL $url");
		}
		return $meta->{'dummy'}
	}
}

sub timerReturn {
	my ( $client, $url ) = @_;
	
	my $hiResTime = getLocalAdjustedTime;

	my $station = &matchStation( $url );

	my $deviceName = "";
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Timer return - no device name");
	} else {
		$deviceName = $client->name;
	};

	my $song = $client->playingSong();
	my $playingURL = "";
	if ( $song && $song->streamUrl ) { $playingURL = $song->streamUrl}

	if ($playingURL ne $url){
		# Given stream URL not the same now as we had before implies listener has changed station
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - timerReturn - client ".$client->name." stream changed to $playingURL");
		# However, it might be an alternative that leads to the same station (redirects) or another in the family so check
		my $newStation = &matchStation( $playingURL );
		
		if ( $station ne $newStation ){
			# Station changed ... so wipe out "old" info ... note ... this timer could have happened after new details were
			# collected for the new stream so this could result in a 2nd push of same info (not an issue)
			# Done because update not sent if new station is simulcast of previous one but loading the new one caused new base info to be loaded by LMS/TuneIn
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - timerReturn - Client: $deviceName - station changed from $station to $newStation");
			undef $meta->{$station}->{title};
			undef $meta->{$station}->{artist};
			$station = $newStation;
		}

		$url = $playingURL;
		main::DEBUGLOG && $log->is_debug && $log->debug("timerReturn - Now set to - $station");
	} else {
		# If streamUrl not found then something is odd - so report it to help determine issue
		if (!$song || !$song->streamUrl || !$song->streamUrl ne ""){
			# Odd?
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - timerReturn - Client: $deviceName - streamUrl issue $playingURL");
		}
	}
	
	if ( $myClientInfo->{$deviceName}->{nextpoll} > $hiResTime ){
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - timerReturn - Client: $deviceName - timer due ".$myClientInfo->{$deviceName}->{nextpoll}." now $hiResTime");
	}
	
	if ($station ne "") {

		my $lastPush = 0;

		if ($myClientInfo->{$deviceName}->{lastpush}) {$lastPush = $myClientInfo->{$deviceName}->{lastpush}};
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Timer return - last push ".$lastPush);

		if ( $client->isPlaying ) {
			&getmeta( $client, $url );
		} else {
			# Not playing - so do nothing - which should result in polls stopping for this device
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Timer return - Client: $deviceName -  but no longer playing");
			
			Slim::Utils::Timers::killTimers($client, \&timerReturn);
			$myClientInfo->{$deviceName}->{nextpoll} = 0;
			$myClientInfo->{$deviceName}->{cover} = "";	# Wipe out the cover info to try to make old cover disappear on resume where no artwork present in fetched data
			# Remove artist and title to force a new push if same details collected on resume
			undef $myClientInfo->{$deviceName}->{title};
			undef $myClientInfo->{$deviceName}->{artist};
			undef $meta->{$station}->{title};
			undef $meta->{$station}->{artist};
		}
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - timerReturn - Just ignored timer expiry because wrong or no station");
	}
}


sub parseContent {
	my ( $client, $content, $station, $url ) = @_;

	my $hiResTime = getLocalAdjustedTime;
	my $songDuration = 0;
	my $progDuration = 0;
	my $hideDuration = $prefs->get('hidetrackduration');
	
	my $info = {
		icon   => $icons->{$station},
		cover  => $icons->{$station},
		artist => undef,
		title  => undef,
		ttl    => $hiResTime + cacheTTL,
		endTime => $hiResTime + cacheTTL,
		startTime => undef,
		isSong => false,
	};
	
	my $deviceName = "";
	my $dataType = '';
	my $thismeta;
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - parseContent - no device name");
	} else {
		$deviceName = $client->name;
	};
	
	my $dumped;
	
	# $dumped = Dumper $calculatedPlaying;
	# print $dumped;
	# main::DEBUGLOG && $log->is_debug && $log->debug("$station - initial calculatedPlaying $dumped");

	if (defined($content) && $content ne ''){
	
		my $guesssong = false;
		if ( $station ){
			if ( exists $stationSet->{$station}->{'guesssong'} ){
				$guesssong = $stationSet->{$station}->{'guesssong'};
			}
		}
		my $artistsignoreregex = getConfig($provider, $station, 'artistsignoreregex');
		
		# main::DEBUGLOG && $log->is_debug && $log->debug("About to decode JSON");

		my $perl_data = eval { from_json( $content ) };

		# $dumped =  Dumper $perl_data;
		# $dumped =~ s/\n {44}/\n/g;   
		# print $dumped;
		
		if (ref($perl_data) ne "ARRAY" && 
		   (exists $perl_data->{'current'}->{'song'} || exists $perl_data->{'current'}->{'emission'})){
			# FIP type
			# Get the data from FIP-style json
			# curl "http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json?_=1430663616447" -H "Cookie: xtvrn=$539041$; has_js=1; xtidc=150221104626734282; xtan=-; xtant=1" -H "Accept-Encoding: gzip, deflate, sdch" -H "Accept-Language: en-US,en;q=0.8" -H "User-Agent: Mozilla/5.0 (Windows NT 6.3; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/42.0.2311.90 Safari/537.36" -H "Accept: application/json, text/javascript, */*; q=0.01" -H"Referer: http://www.fipradio.fr/" -H "X-Requested-With: XMLHttpRequest" -H "Connection: keep-alive" --compressed
			# Sample Response
			# {
			#   "current": {
			#     "emission": {
			#       "startTime": 1430604000,
			#       "endTime": 1430690399,
			#       "id": "827cf10424ff6e7448cf64000b9d96fc",
			#       "titre": "",
			#       "visuel": {
			#         "small": "http:\/\/www.fipradio.fr\/sites\/all\/modules\/fip\/fip_direct\/images\/direct_default_cover.png"
			#       },
			#       "lien": "http:\/\/www.fipradio.fr\/"
			#     },
			#     "song": {
			#       "startTime": 1430663558,
			#       "endTime": 1430663833,
			#       "id": "fd8c35c9904ec38c0e3858407e663c00",
			#       "titre": "EBAKESH TAREQIGN",
			#       "titreAlbum": "ETHIOPIQUES 7",
			#       "interpreteMorceau": "MAHMOUD AHMED",
			#       "anneeEditionMusique": "1975",
			#       "label": "BUDA",
			#       "visuel": {
			#         "small": "http:\/\/www.fipradio.fr\/sites\/all\/modules\/fip\/fip_direct\/images\/direct_default_cover.png",
			#         "medium": "http:\/\/www.fipradio.fr\/sites\/all\/modules\/fip\/fip_direct\/images\/direct_default_cover_medium.png"
			#       },
			#       "lien": "http:\/\/www.fipradio.fr\/"
			#     }
			#   },
			#   "previous2": {
			#     "song": {
			#       "startTime": 1430663033,
			#       "endTime": 1430663361,
			#       "id": "673b0e2bbe3ef07c9940e4b6aa182bfd",
			#       "titre": "TEN LAKES",
			#       "titreAlbum": "OPENING",
			#       "interpreteMorceau": "SUPERPOZE",
			#       "anneeEditionMusique": "2015",
			#       "label": "COMBIEN MILLE RECORDS",
			#       "visuel": {
			#         "small": "http:\/\/is4.mzstatic.com\/image\/pf\/us\/r30\/Music5\/v4\/95\/15\/19\/951519a3-b00c-8f0c-4d26-f61e3d31874e\/886445145571.100x100-75.jpg",
			#         "medium": "http:\/\/is4.mzstatic.com\/image\/pf\/us\/r30\/Music5\/v4\/95\/15\/19\/951519a3-b00c-8f0c-4d26-f61e3d31874e\/886445145571.400x400-75.jpg"
			#       },
			#       "lien": "https:\/\/itunes.apple.com\/fr\/album\/ten-lakes\/id976333324?i=976333865&uo=4"
			#     }
			#   },
			#   "previous1": {
			#     "song": {
			#       "startTime": 1430663358,
			#       "endTime": 1430663562,
			#       "id": "0812e1f7ab41ddc2cfa109608b1fa5af",
			#       "titre": "SAMAR",
			#       "titreAlbum": "YA NASS (CD PROMO FIP)",
			#       "interpreteMorceau": "YASMINE HAMDAN",
			#       "anneeEditionMusique": "2013",
			#       "label": "KWAIDAN RECORDS",
			#       "visuel": {
			#         "small": "http:\/\/is2.mzstatic.com\/image\/pf\/us\/r30\/Music\/v4\/80\/12\/04\/801204cb-4605-2df7-c517-0873d2de29c1\/cover.100x100-75.jpg",
			#         "medium": "http:\/\/is2.mzstatic.com\/image\/pf\/us\/r30\/Music\/v4\/80\/12\/04\/801204cb-4605-2df7-c517-0873d2de29c1\/cover.400x400-75.jpg"
			#       },
			#       "lien": "https:\/\/itunes.apple.com\/fr\/album\/samar\/id628030477?i=628030517&uo=4"
			#     }
			#   },
			#   "next1": {
			#     "song": {
			#       "startTime": 1430663828,
			#       "endTime": 1430663993,
			#       "id": "01e4a6d4012a06995aeec279bb250e13",
			#       "titre": "PRAELUDIUM EN FA MAJ",
			#       "titreAlbum": "PAAVO BERGLUND : THE BOURNEMOUTH YEARS",
			#       "interpreteMorceau": "ARMAS JARNEFELT\/DIR PAAVO BERGLUND\/ORCHESTRE SYMPHONIQUE DE BOURNEMOUTH",
			#       "anneeEditionMusique": "2013",
			#       "label": "WARNER CLASSIC",
			#       "visuel": {
			#         "small": "http:\/\/www.fipradio.fr\/sites\/all\/modules\/fip\/fip_direct\/images\/direct_default_cover.png",
			#         "medium": "http:\/\/www.fipradio.fr\/sites\/all\/modules\/fip\/fip_direct\/images\/direct_default_cover_medium.png"
			#       },
			#       "lien": "http:\/\/www.fipradio.fr\/"
			#     }
			#   },
			#   "next2": {
			#     "song": {
			#       "startTime": 1430663988,
			#       "endTime": 1430664209,
			#       "id": "c40738f64dc01bc1639af1d7a379a878",
			#       "titre": "LIKE THE MORNING DEW",
			#       "titreAlbum": "LAURA MVULA WITH METROPOLE ORKEST CONDUCTED BY JULES BUCKLEY AT ABBEY ROAD",
			#       "interpreteMorceau": "LAURA MVULA",
			#       "anneeEditionMusique": "2014",
			#       "label": "SONY",
			#       "visuel": {
			#         "small": "http:\/\/is2.mzstatic.com\/image\/pf\/us\/r30\/Features6\/v4\/86\/49\/d4\/8649d40c-00d5-778f-39b0-bdffba7ffb4c\/dj.eouevxfi.100x100-75.jpg",
			#         "medium": "http:\/\/is2.mzstatic.com\/image\/pf\/us\/r30\/Features6\/v4\/86\/49\/d4\/8649d40c-00d5-778f-39b0-bdffba7ffb4c\/dj.eouevxfi.400x400-75.jpg"
			#       },
			#       "lien": "https:\/\/itunes.apple.com\/fr\/album\/like-the-morning-dew\/id584469854?i=584469856&uo=4"
			#     }
			#   }
			# }			
			
			$dataType = 'rf1';
			
			my $nowplaying = $perl_data->{'current'}->{'song'};

			if (exists $perl_data->{'current'}->{'emission'}->{'startTime'} && exists $perl_data->{'current'}->{'emission'}->{'endTime'} &&
				$hiResTime >= $perl_data->{'current'}->{'emission'}->{'startTime'} && $hiResTime <= $perl_data->{'current'}->{'emission'}->{'endTime'}+30) {
				# Station / Programme name provided so use that if it is on now - e.g. gives real current name for FIP Evenement
			
				if (exists $perl_data->{'current'}->{'emission'}->{'titre'} && $perl_data->{'current'}->{'emission'}->{'titre'} ne ''){
					$calculatedPlaying->{$station}->{'progtitle'} = $perl_data->{'current'}->{'emission'}->{'titre'};
				}
				
				$calculatedPlaying->{$station}->{'progsubtitle'} = '';
				$calculatedPlaying->{$station}->{proglogo} = '';
				
				if ($prefs->get('showprogimage')){
					my $progIcon = '';

					if (exists $perl_data->{'current'}->{'emission'}->{'visuel'}->{'medium'}){
						# Station / Programme icon provided so use that - e.g. gives real current icon for FIP Evenement
						$progIcon = $perl_data->{'current'}->{'emission'}->{'visuel'}->{'medium'};
					}
				
					if ($progIcon eq '' && exists $perl_data->{'current'}->{'emission'}->{'visuel'}->{'small'}){
						# Station / Programme icon provided so use that - e.g. gives real current icon for FIP Evenement
						$progIcon = $perl_data->{'current'}->{'emission'}->{'visuel'}->{'small'};
					}

					if ($progIcon ne '' && $progIcon !~ /$iconsIgnoreRegex->{$station}/ ){
						$calculatedPlaying->{$station}->{proglogo} = $progIcon;
					} else {
						# Icon not present or matches one to be ignored
						# if ($progIcon ne ''){main::DEBUGLOG && $log->is_debug && $log->debug("Prog Image skipped: $progIcon");}
					}
				}
			}
			
			if (defined($nowplaying) ) {
			
				if ( $nowplaying->{'endTime'} < $hiResTime ){
					# Looks like the current song has finished so try to get the details from the next one
					# main::DEBUGLOG && $log->is_debug && $log->debug("Current song finished - so try next");
					if ( $perl_data->{'next1'}->{'song'} ){
						$nowplaying = $perl_data->{'next1'}->{'song'};
						# main::DEBUGLOG && $log->is_debug && $log->debug("Grabbed next");
					}
				}
				# $dumped =  Dumper $nowplaying;
				# $dumped =~ s/\n {44}/\n/g;   
				# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

				# main::DEBUGLOG && $log->is_debug && $log->debug("Time: ".time." Ends: ".$nowplaying->{'endTime'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current artist: ".$nowplaying->{'interpreteMorceau'}." song: ".$nowplaying->{'titre'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Image:\n small: ".$nowplaying->{'visuel'}->{small}."\n medium: ".$nowplaying->{'visuel'}->{medium});

				if (exists $nowplaying->{'startTime'}){ $calculatedPlaying->{$station}->{progstart} = $nowplaying->{'startTime'}};
				
				my $expectedEndTime = $hiResTime;
				
				if (exists $nowplaying->{'endTime'}){ $expectedEndTime = $nowplaying->{'endTime'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly
					if (exists $nowplaying->{'interpreteMorceau'}) {$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'interpreteMorceau'})};
					if (exists $nowplaying->{'titre'}) {$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($nowplaying->{'titre'})};
					$calculatedPlaying->{$station}->{'songyear'} = '';
					if (exists $nowplaying->{'anneeEditionMusique'}) {$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'anneeEditionMusique'}};
					$calculatedPlaying->{$station}->{'songlabel'} = '';
					if (exists $nowplaying->{'label'}) {$calculatedPlaying->{$station}->{'songlabel'} = _lowercase($nowplaying->{'label'})};
					
					$calculatedPlaying->{$station}->{'songalbum'} = '';
					if (exists $nowplaying->{'titreAlbum'}) {$calculatedPlaying->{$station}->{'songalbum'} = _lowercase($nowplaying->{'titreAlbum'})};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					if ($nowplaying->{'visuel'}->{medium}){
						$thisartwork = $nowplaying->{'visuel'}->{medium};
					} else {
						if ($nowplaying->{'visuel'}->{small}){
							$thisartwork = $nowplaying->{'visuel'}->{small};
						}
					}
					
					if ($thisartwork ne '' && ($thisartwork !~ /$iconsIgnoreRegex->{$station}/ || $thisartwork eq $info->{icon}) ){
						$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
					} else {
						# Icon not present or matches one to be ignored
						# main::DEBUGLOG && $log->is_debug && $log->debug("Image:\n small: ".$nowplaying->{'visuel'}->{small}."\n medium: ".$nowplaying->{'visuel'}->{medium});
					}
					
					if ( exists $nowplaying->{'endTime'} && exists $nowplaying->{'startTime'} ){
						# Work out song duration and return (plausibility checks done later in generic code)
						$songDuration = $nowplaying->{'endTime'} - $nowplaying->{'startTime'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ( $songDuration > 0 ) {
							$calculatedPlaying->{$station}->{songlth} = $songDuration
						} else {
							$calculatedPlaying->{$station}->{songlth} = 0;
						};
					}
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$calculatedPlaying->{$station}->{'songend'} = $expectedEndTime;
					
					#$dumped =  Dumper $calculatedPlaying;
					#$dumped =~ s/\n {44}/\n/g;   
					#main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");

				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				# print("Did not find Current Song in retrieved data");

			}
		} elsif (ref($perl_data) ne "ARRAY" && exists $perl_data->{'levels'}){
			# France Musique type
				# France Musique-style json
			# curl "https://www.francemusique.fr/livemeta/pull/407"
			# Sample Response
			  # {
				# "steps": {
				  # "a6a483a378726db44a2ba95d5ab721f5": {
				  # "uuid": "1de61e21-e7b3-42fd-9757-d2d1caa4ce6a",
				  # "stepId": "a6a483a378726db44a2ba95d5ab721f5",
				  # "title": "Piccolo & saxo : Stradi variations 1",
				  # "start": 1486030316,
				  # "end": 1486030411,
				  # "fatherStepId": null,
				  # "stationId": 407,
				  # "embedId": "0825646430321-1-7",
				  # "embedType": "song",
				  # "depth": 3,
				  # "authors": "Andre Popp",
				  # "titleSlug": "piccolo-saxo-stradi-variations-1",
				  # "songId": "b8a67eef-d394-47b8-956b-493ddf27940b",
				  # "visual": "https:\/\/www.francebleu.fr\/s3\/cruiser-production\/2016\/12\/01db3c9b-30b7-42a3-be3f-3ebd1ba999a8\/400x400_rf_omm_0000352486_dnc.0057691771.jpg",
				  # "titreAlbum": "Bof \/ Piccolo, Saxo et Compagnie 2006",
				  # "label": "WARNER MUSIC FRANCE",
				  # "releaseId": "c5ecc2b7-a0dd-460f-954d-46b405f2389e",
				  # "coverUuid": "01db3c9b-30b7-42a3-be3f-3ebd1ba999a8"
				# },
				# "5ad9f6f52ab4d4fe88f06d637c0a9474": {
				  # "uuid": "3b55c556-0a1f-4309-ba82-96fe7f3a1b1b",
				  # "stepId": "5ad9f6f52ab4d4fe88f06d637c0a9474",
				  # "title": "Piccolo & saxo : Piccolo sur sa feuille",
				  # "start": 1486030412,
				  # "end": 1486030470,
				  # "fatherStepId": null,
				  # "stationId": 407,
				  # "embedId": "0825646430321-1-8",
				  # "embedType": "song",
				  # "depth": 3,
				  # "authors": "Andre Popp",
				  # "titleSlug": "piccolo-saxo-piccolo-sur-sa-feuille",
				  # "songId": "ebfb3fda-2207-4722-9065-44cf97ccf499",
				  # "visual": "https:\/\/www.francebleu.fr\/s3\/cruiser-production\/2016\/12\/01db3c9b-30b7-42a3-be3f-3ebd1ba999a8\/400x400_rf_omm_0000352486_dnc.0057691771.jpg",
				  # "titreAlbum": "Bof \/ Piccolo, Saxo et Compagnie 2006",
				  # "label": "WARNER MUSIC FRANCE",
				  # "releaseId": "c5ecc2b7-a0dd-460f-954d-46b405f2389e",
				  # "coverUuid": "01db3c9b-30b7-42a3-be3f-3ebd1ba999a8"
				# },
				# "32c86e4f5c3e38aac485c8dbe59e39ce": {
				  # "uuid": "5e12984b-1b5c-47a1-b6a3-062383cd027e",
				  # "stepId": "32c86e4f5c3e38aac485c8dbe59e39ce",
				  # "title": "Piccolo & saxo : Fanfare",
				  # "start": 1486030470,
				  # "end": 1486030537,
				  # "fatherStepId": null,
				  # "stationId": 407,
				  # "embedId": "0825646430321-1-9",
				  # "embedType": "song",
				  # "depth": 3,
				  # "authors": "Andre Popp",
				  # "titleSlug": "piccolo-saxo-fanfare",
				  # "songId": "9e49f9ad-63eb-40d2-a196-b56b67551e31",
				  # "visual": "https:\/\/www.francebleu.fr\/s3\/cruiser-production\/2016\/12\/01db3c9b-30b7-42a3-be3f-3ebd1ba999a8\/400x400_rf_omm_0000352486_dnc.0057691771.jpg",
				  # "titreAlbum": "Bof \/ Piccolo, Saxo et Compagnie 2006",
				  # "label": "WARNER MUSIC FRANCE",
				  # "releaseId": "c5ecc2b7-a0dd-460f-954d-46b405f2389e",
				  # "coverUuid": "01db3c9b-30b7-42a3-be3f-3ebd1ba999a8"
				# },
				# "11cf58e7d90259cef5550a3fb446eb11": {
				  # "uuid": "b4d96256-3ee5-4555-b174-dd37b3f59c22",
				  # "stepId": "11cf58e7d90259cef5550a3fb446eb11",
				  # "title": "Piccolo & saxo : Le toboggan",
				  # "start": 1486030538,
				  # "end": 1486030580,
				  # "fatherStepId": null,
				  # "stationId": 407,
				  # "embedId": "0825646430321-1-10",
				  # "embedType": "song",
				  # "depth": 3,
				  # "authors": "Andre Popp",
				  # "titleSlug": "piccolo-saxo-le-toboggan",
				  # "songId": "af9e9ade-5dd4-492b-8bde-d93e49128eda",
				  # "visual": "https:\/\/www.francebleu.fr\/s3\/cruiser-production\/2016\/12\/01db3c9b-30b7-42a3-be3f-3ebd1ba999a8\/400x400_rf_omm_0000352486_dnc.0057691771.jpg",
				  # "titreAlbum": "Bof \/ Piccolo, Saxo et Compagnie 2006",
				  # "label": "WARNER MUSIC FRANCE",
				  # "releaseId": "c5ecc2b7-a0dd-460f-954d-46b405f2389e",
				  # "coverUuid": "01db3c9b-30b7-42a3-be3f-3ebd1ba999a8"
				# }
			  # },
			  # "levels": [
				# {
				  # "items": [
					# "a6a483a378726db44a2ba95d5ab721f5",
					# "5ad9f6f52ab4d4fe88f06d637c0a9474",
					# "32c86e4f5c3e38aac485c8dbe59e39ce",
					# "11cf58e7d90259cef5550a3fb446eb11"
				  # ],
				  # "position": 3
				# }
			  # ],
			  # "stationId": 407
			  # }
			  
			  # France Inter - broadly same but different fields because they are programmes rather than songs
			      # "f75d7e63-c798-4bc2-8fd1-8aa1258fb58e_1": {
				      # "uuid": "4a74197e-1165-4d21-9841-5701df662093",
				      # "stepId": "f75d7e63-c798-4bc2-8fd1-8aa1258fb58e_1",
				      # "title": "\"Chacun pour tous\" et tous pour Jean-Pierre Darroussin et Ahmed Sylla",
				      # "start": 1539767070,
				      # "end": 1539770280,
				      # "fatherStepId": null,
				      # "stationId": 1,
				      # "embedId": "7605f350-2ea0-003c-e053-0ae0df142a66",
				      # "embedType": "expression",
				      # "depth": 1,
				      # "discJockey": null,
				      # "expressionUuid": "0c4136ae-813c-4589-8709-100c54f5e86a",
				      # "conceptUuid": "8a097b4a-26eb-11e4-907f-782bcb6744eb",
				      # "businessReference": "22804",
				      # "magnetothequeId": "2018F22804S0290",
				      # "titleConcept": "La Bande originale",
				      # "titleSlug": "chacun-pour-tous-et-tous-pour-jean-pierre-darroussin-et-ahmed-sylla",
				      # "visual": "d9a58aa1-e565-453d-a27c-2324540c6b1f",
				      # "visualBanner": "47a8f6b0-6aed-40e5-acdd-5d80430aba9c",
				      # "producers": [
					# {
					  # "uuid": "4339d7bc-26eb-11e4-907f-782bcb6744eb",
					  # "name": " Nagui"
					# }
				      # ],
				      # "path": "emissions\/la-bande-originale\/la-bande-originale-17-octobre-2018",
				      # "expressionDescription": "Ce matin, Jean-Pierre Darroussin et Ahmed Sylla sont les invit\u00e9s de la Bande original pour le film de Vianney Lebasque \u201cChacun pour tous\u201d en salles le 31 octobre.",
				      # "description": "Au programme de cette quatri\u00e8me saison : toujours de la bonne humeur et de l\u2019impertinence pour une \u00e9mission dr\u00f4le et joyeuse ! "
				    # },
				    
				    # and here is a sub-section within another programme. It has "fatherStepId" ... tricky ... 
				        # "1252bc86-d460-42db-8283-47ad6e4106d2_1": {
					      # "uuid": "a7ee8cef-bb98-4214-9ff1-852a61ac7523",
					      # "stepId": "1252bc86-d460-42db-8283-47ad6e4106d2_1",
					      # "title": "L'Arabie Saoudite, le Disneyland de l'horreur",
					      # "start": 1539770820,
					      # "end": 1539771000,
					      # "fatherStepId": "58e51839-ab01-45bf-8936-d4c54d1d2a98_1",
					      # "stationId": 1,
					      # "embedId": "7605f350-2ea3-003c-e053-0ae0df142a66",
					      # "embedType": "expression",
					      # "depth": 2,
					      # "discJockey": null,
					      # "expressionUuid": "40335751-efe8-42aa-b9ce-24d3d55da76d",
					      # "conceptUuid": "eaf66c64-99e0-45a7-8eb3-d74fa59659a2",
					      # "businessReference": "29767",
					      # "magnetothequeId": "2018F29767S0290",
					      # "titleConcept": "Tanguy Pastureau maltraite l'info",
					      # "titleSlug": "l-arabie-saoudite-le-disneyland-de-l-horreur",
					      # "visual": "8a7bf96b-7b35-4402-88fe-092d718e1682",
					      # "visualBanner": "26259170-7522-4ba4-98c0-6923df08b4d8",
					      # "producers": [
						# {
						  # "uuid": "1cc4347f-17f6-4c7e-842c-e544130a234e",
						  # "name": "Tanguy Pastureau"
						# }
					      # ],
					      # "path": "emissions\/tanguy-pastureau-maltraite-l-info\/tanguy-pastureau-maltraite-l-info-17-octobre-2018",
					      # "expressionDescription": "Jusqu'\u00e0 r\u00e9cemment, on nous pr\u00e9sentait l'Arabie Saoudite comme un pays g\u00e9nial"
					    # },

			$dataType = 'rf2';
			my $nowplaying;
			my $parentItem = '';
			my $thisItem;
			
			# Try to find what is playing (priority to song over programme)
			
			if (exists $perl_data->{'levels'}){
				my @levels = @{ $perl_data->{'levels'} };
					
				# $dumped =  Dumper @levels;
				# print $dumped;

				if (exists $levels[0]{items}) {
				
					foreach my $levelentry (@levels){
						# $dumped = Dumper $levelentry->{items};
						# print $dumped;
					
						if (exists $levelentry->{items}) {
							my $items = $levelentry->{items};
							
							#  Try to match the time rather than use the "position" pointer just in case it is out of date
							foreach my $item ( @$items ){
								# Array of "items" contains id of objects that contain more data
								# main::DEBUGLOG && $log->is_debug && $log->debug("item: $item");
								
								if (exists $perl_data->{steps}->{$item}){
									# the step exists so check the start / end to see if this is now
									$thisItem = $perl_data->{steps}->{$item};
									
									# main::DEBUGLOG && $log->is_debug && $log->debug("Now: $hiResTime Start: ".$perl_data->{steps}->{$item}->{'start'}." End: $perl_data->{steps}->{$item}->{'end'}");
									
									if ( exists $thisItem->{'start'} && $thisItem->{'start'} <= $hiResTime && 
										exists $thisItem->{'end'} && $thisItem->{'end'} >= $hiResTime &&
										!$info->{isSong}) {
										# This one is in range and not already found a song (might have found a programme or segment but song trumps it)
										# main::DEBUGLOG && $log->is_debug && $log->debug("Current playing $item");
										if ((exists $thisItem->{'title'} && $thisItem->{'title'} ne '' && 
										    exists $thisItem->{'embedType'} && $thisItem->{'embedType'} ne 'song' &&
										    (!exists $thisItem->{'authors'} || ref($thisItem->{'authors'}) eq 'ARRAY') && 
										    !exists $thisItem->{'performers'} && 
										    !exists $thisItem->{'composers'}) ||
										    $thisItem->{'end'} - $thisItem->{'start'} > maxSongLth )
										    {
											# If there is a title but no authors/performers/composers OR too long for a song then this is a show not a song
											$progDuration = $thisItem->{'end'} - $thisItem->{'start'};
											main::DEBUGLOG && $log->is_debug && $log->debug("$station Found programme: $thisItem->{'title'} - duration: $progDuration");
											$calculatedPlaying->{$station}->{'progtitle'} = $thisItem->{'title'};
											$calculatedPlaying->{$station}->{'progsubtitle'} = '';
											
											my $parentTitle = '';
											$calculatedPlaying->{$station}->{progsynopsis} = '';
											
											if (!exists $calculatedPlaying->{$station}->{'progsynopsis'} || $calculatedPlaying->{$station}->{'progsynopsis'} eq ''){
												if (exists $thisItem->{'expressionDescription'} && 
												   $thisItem->{'expressionDescription'} ne '' && 
												   $thisItem->{'expressionDescription'} ne '.' && 
												   $thisItem->{'expressionDescription'} ne '...')
												{
													# If not already collected a synopsis then take this one
													$calculatedPlaying->{$station}->{'progsynopsis'} = $thisItem->{'expressionDescription'};
												} elsif (exists $thisItem->{'description'} && $thisItem->{'description'} ne ''){
													# Try Description instead
													$calculatedPlaying->{$station}->{'progsynopsis'} = $thisItem->{'description'};
												}
											}

											if (exists $thisItem->{'titleConcept'} && $thisItem->{'titleConcept'} ne ''){
												# titleConcept (if present) is the name of the show as a whole and then title is the episode/instance name
												$parentTitle = $thisItem->{'titleConcept'};
												
											} elsif (exists $thisItem->{'fatherStepId'} && defined($thisItem->{'fatherStepId'}) && $thisItem->{'fatherStepId'} ne ''){
												# There appears to be a parent item ... so if valid then use info from it
												$parentItem = $thisItem->{'fatherStepId'};
												main::DEBUGLOG && $log->is_debug && $log->debug("$station Parent: ".$parentItem);
												if (exists $perl_data->{steps}->{$parentItem}){
													# Parent item is present
													if (exists $perl_data->{steps}->{$parentItem}->{'titleConcept'} || exists $perl_data->{steps}->{$parentItem}->{'title'}){
														# Appears to have a name
														if (exists $perl_data->{steps}->{$parentItem}->{'titleConcept'} && $perl_data->{steps}->{$parentItem}->{'titleConcept'} ne ''){
															$parentTitle = $perl_data->{steps}->{$parentItem}->{'titleConcept'};
														} elsif (exists $perl_data->{steps}->{$parentItem}->{'title'} && $perl_data->{steps}->{$parentItem}->{'title'} ne ''){
															$parentTitle = $perl_data->{steps}->{$parentItem}->{'title'};
														}
													}
													
													if (!exists $calculatedPlaying->{$station}->{'progsynopsis'} || $calculatedPlaying->{$station}->{'progsynopsis'}){
														if (exists $perl_data->{steps}->{$parentItem}->{'expressionDescription'} && 
														    $perl_data->{steps}->{$parentItem}->{'expressionDescription'} ne '' && 
														    $perl_data->{steps}->{$parentItem}->{'expressionDescription'} ne '.' && 
														    $perl_data->{steps}->{$parentItem}->{'expressionDescription'} ne '...')
														{
															# If not already collected a synopsis then take this one
															$calculatedPlaying->{$station}->{'progsynopsis'} = $perl_data->{steps}->{$parentItem}->{'expressionDescription'};
														} elsif (exists $perl_data->{steps}->{$parentItem}->{'description'} && $perl_data->{steps}->{$parentItem}->{'description'} ne ''){
															# Try Description instead
															$calculatedPlaying->{$station}->{'progsynopsis'} = $perl_data->{steps}->{$parentItem}->{'description'};
														}
													}
												}
											}
											
											if ($parentTitle ne ''){
												# Have both fields - but only include first if not already included in second to reduce line length to reduce chance of scrolling
												# if ($thisItem->{'title'} !~ /^\Q$parentTitle\E/i ){
												# 	$calculatedPlaying->{$station}->{'progtitle'} = $parentTitle." / ".$thisItem->{'title'};
												# }
												$calculatedPlaying->{$station}->{'progtitle'} = $parentTitle;
												$calculatedPlaying->{$station}->{'progsubtitle'} = $thisItem->{'title'};
												main::DEBUGLOG && $log->is_debug && $log->debug("$station Found subprogramme: ".$calculatedPlaying->{$station}->{'progsubtitle'});
											}
											
											if (exists $thisItem->{'start'}){ $calculatedPlaying->{$station}->{'progstart'} = $thisItem->{'start'}};
											if (exists $thisItem->{'end'}){ $calculatedPlaying->{$station}->{'progend'} = $thisItem->{'end'}};
											
											$calculatedPlaying->{$station}->{'proglth'} = 0;
											
											if ( exists $thisItem->{'end'} && exists $thisItem->{'start'} ){
												# Work out programme duration and return if plausible
												$progDuration = $thisItem->{'end'} - $thisItem->{'start'};
												
												# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Show Duration $progDuration");
												
												if ( $progDuration > 0 ) {$calculatedPlaying->{$station}->{'proglth'} = $progDuration};
											}
											
											# Artwork - only include if not one of the defaults - to give chance for something else to add it
											# Regex check to see if present using $iconsIgnoreRegex
											
											my $thisartwork = '';
												
											$thisartwork = getcover($thisItem, $station, $info);

											$calculatedPlaying->{$station}->{'proglogo'} = $thisartwork;
											
											main::DEBUGLOG && $log->is_debug && $log->debug("Found show name in Type $dataType: $calculatedPlaying->{$station}->{'progtitle'}");
										} else {
											$nowplaying = $thisItem;
											$info->{isSong} = true;
										}
									}
								} else {
									# Unexpected - so log it
									main::INFOLOG && $log->is_info && $log->info("$station - Failed to find $item in 'steps'");
									undef $nowplaying;
								}
							}
						}
					}
				} else {
					# Expected data not present - could be a temporary comms error or they have changed their data structure
					main::INFOLOG && $log->is_info && $log->info("$station - Failed to find 'items' in received data");
				}
			} else {
				# Expected data not present - could be a temporary comms error or they have changed their data structure
				main::INFOLOG && $log->is_info && $log->info("$station - Failed to find 'levels' in received data");
			}
			
			if ( $info->{isSong} ) {
			
				# $dumped =  Dumper $nowplaying;
				# $dumped =~ s/\n {44}/\n/g;   
				# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

				# main::DEBUGLOG && $log->is_debug && $log->debug("Time: ".time." Ends: ".$nowplaying->{'end'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current artist: ".$nowplaying->{'performers'}." song: ".$nowplaying->{'title'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$nowplaying->{'visual'});
				
				if (exists $nowplaying->{'start'}){ $calculatedPlaying->{$station}->{'songstart'} = $nowplaying->{'start'}};
				
				my $expectedEndTime = $hiResTime;
				
				if (exists $nowplaying->{'end'}){ $expectedEndTime = $nowplaying->{'end'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

					$calculatedPlaying->{$station}->{'songartist'} = '';
					if (exists $nowplaying->{'performers'} && $nowplaying->{'performers'} ne '') {
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'performers'});
					} elsif (exists $nowplaying->{'authors'} && $nowplaying->{'authors'} ne ''){
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'authors'});
					} elsif (exists $nowplaying->{'composers'} && $nowplaying->{'composers'} ne '') {
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'composers'});
					};
					
					$calculatedPlaying->{$station}->{'songtitle'} = '';
					if (exists $nowplaying->{'titleConcept'} && $nowplaying->{'titleConcept'} ne ''){
						# titleConcept used for programmes in a series - in which case title is the episode/instance name
						# No need to fiddle with the case as they do use mixed for this so all lowercase probably deliberate
						$calculatedPlaying->{$station}->{'songtitle'} = $nowplaying->{'titleConcept'};
					} else {
						if (exists $nowplaying->{'title'}) {$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($nowplaying->{'title'})};
					}
					
					$calculatedPlaying->{$station}->{'songyear'} = '';
					if (exists $nowplaying->{'anneeEditionMusique'}) {$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'anneeEditionMusique'}};
					$calculatedPlaying->{$station}->{'songlabel'} = '';
					if (exists $nowplaying->{'label'}) {$calculatedPlaying->{$station}->{'songlabel'} = _lowercase($nowplaying->{'label'})};
					
					# main::DEBUGLOG && $log->is_debug && $log->debug('Preferences: DisableAlbumName='.$prefs->get('disablealbumname'));
					$calculatedPlaying->{$station}->{'songalbum'} = '';
					if (exists $nowplaying->{'titreAlbum'}) {$calculatedPlaying->{$station}->{'songalbum'} = _lowercase($nowplaying->{'titreAlbum'})};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					$thisartwork = getcover($nowplaying, $station, $info);
					
					#if ($thisartwork ne ''){
						$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
					#}
					
					if ( exists $nowplaying->{'end'} && exists $nowplaying->{'start'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'end'} - $nowplaying->{'start'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0) {$calculatedPlaying->{$station}->{'songlth'} = $songDuration};
					}
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$calculatedPlaying->{$station}->{'songend'} = $expectedEndTime;
					
				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("$station ($dataType) - Did not find Current Song in retrieved data");

			}
			
			#$dumped =  Dumper $calculatedPlaying->{$station};
			#$dumped =~ s/\n {44}/\n/g;   
			#main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");

		} elsif (ref($perl_data) ne "ARRAY" && exists $perl_data->{'data'} && ref($perl_data->{'data'}) ne "ARRAY" &&
			( ( exists $perl_data->{'data'}->{'now'}->{'playing_item'} ) ||
			
			( exists $perl_data->{'data'}->{'nowList'} && ref($perl_data->{'data'}->{'nowList'}) eq "ARRAY" &&
			  exists($perl_data->{'data'}->{'nowList'}[0]->{'playing_item'}) ) ) ) {
			# Sample response from Mouv' additional stations (from Feb-2019)
			# Note - do not know where the sha1 ref for the persistent search comes from but seems to be consistent across stations
			# https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A605%7D&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22a6f39630b68ceb8e56340a4478e099d05c9f5fc1959eaccdfb81e2ce295d82a5%22%7D%7D
			# Note 2: returned data seen with 0 for start_time/end_time ... so treat that as Now
			# {
			  # "data": {
				# "now": {
				  # "__typename": "Now",
				  # "playing_item": {
					# "__typename": "TimelineItem",
					# "title": "ORELSAN (feat DAMSO)",
					# "subtitle": "Reves Bizarres",
					# "cover": "https:\/\/e-cdns-images.dzcdn.net\/images\/cover\/c05a1a7fcc1c2b0672d998ce7c492664\/1000x1000-000000-80-0-0.jpg",
					# "start_time": 1549974775,
					# "end_time": 1549974985
				  # },
				  # "server_time": 1549974955,
				  # "next_refresh": 1549974986,
				  # "mode": "song"
				# }
			  # }
			# }
			# Sample response from FIP (from June-2020)
			# Note - do not know where the sha1 ref for the persistent search comes from but seems to be consistent across stations
			# https://www.fip.fr/latest/api/graphql?operationName=NowList&variables=%7B%22bannerPreset%22%3A%22266x266%22%2C%22stationIds%22%3A%5B78%5D%7D&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22151ca055b816d28507dae07f9c036c02031ed54e18defc3d16feee2551e9a731%22%7D%7D
			# Note 2: returned data seen with 0 for start_time/end_time ... so treat that as Now
			# {
			  # "data": {
			    # "nowList": [
			      # {
				# "__typename": "Now",
				# "playing_item": {
				  # "__typename": "TimelineItem",
				  # "title": "Perfume Genius",
				  # "subtitle": "Without you",
				  # "cover": "https://cdn.radiofrance.fr/s3/cruiser-production/2020/05/7787e973-836a-4ba6-8a7d-0c9f2c0f3a42/266x266_rf_omm_0001859963_dnc.0091485432.jpg",
				  # "start_time": 1592414796,
				  # "end_time": 1592414948,
				  # "year": 2020
				# },
				# "program": null,
				# "song": {
				  # "__typename": "SongOnAir",
				  # "uuid": "44546d7e-71fb-495d-b597-d64727e15b9e",
				  # "cover": "https://cdn.radiofrance.fr/s3/cruiser-production/2020/05/7787e973-836a-4ba6-8a7d-0c9f2c0f3a42/266x266_rf_omm_0001859963_dnc.0091485432.jpg",
				  # "title": "Without you",
				  # "interpreters": [
				    # "Perfume Genius"
				  # ],
				  # "musical_kind": "Pop / pop rock ",
				  # "label": "MATADOR",
				  # "album": "Set my heart on fire immediately",
				  # "year": 2020,
				  # "external_links": {
				    # "youtube": null,
				    # "deezer": {
				      # "id": "954817182",
				      # "link": "https://www.deezer.com/track/954817182",
				      # "image": "https://cdns-images.dzcdn.net/images/cover/250ce7730b9183b05e004257861b3330/1000x1000-000000-80-0-0.jpg",
				      # "__typename": "ExternalLink"
				    # },
				    # "itunes": null,
				    # "spotify": {
				      # "id": "2SPxgEush9C8GS5RqgXdqi",
				      # "link": "https://open.spotify.com/track/2SPxgEush9C8GS5RqgXdqi",
				      # "image": "https://i.scdn.co/image/ab67616d0000b2739af34850f5125ef195d6101a",
				      # "__typename": "ExternalLink"
				    # },
				    # "__typename": "ExternalLinks"
				  # }
				# },
				# "server_time": 1592414926,
				# "next_refresh": 1592414949,
				# "mode": "song"
			      # }
			    # ]
			  # }
			# }


			$dataType = 'rf3';
			my $nowplaying;
			my $thisItem;
			my $songItem;
			
			# Try to find what is playing (priority to song over programme)
			if ( exists($perl_data->{'data'}->{'now'}->{'playing_item'}) ){
				$thisItem = $perl_data->{'data'}->{'now'}->{'playing_item'};
			} else {
				$thisItem = $perl_data->{'data'}->{'nowList'}[0]->{'playing_item'};
				
				# Have seen data quality issues where artist is missing from "TimelineItem" but it is in "Song"
				# As a consequence the item was being classified as a programme not a song ... so force to be a song
				# if there appears to be enough song data
				if ( exists($perl_data->{'data'}->{'nowList'}[0]->{'song'} ) ){
					$songItem = $perl_data->{'data'}->{'nowList'}[0]->{'song'};
					
					if (exists($songItem->{'title'}) && defined($songItem->{'title'})  && $songItem->{'title'} ne '' &&
					    exists($songItem->{'interpreters'}) && ref($songItem->{'interpreters'}) eq "ARRAY" && $songItem->{'interpreters'}[0] ne '' ){
						$info->{isSong} = true;
					}
				}
			}
			
			# main::DEBUGLOG && $log->is_debug && $log->debug("Now: $hiResTime Start: ".$thisitem->{'start_time'}." End: $thisitem->{'end_time'}");
			
			if ( exists $thisItem->{'start_time'} && $thisItem->{'start_time'} <= $hiResTime && 
				exists $thisItem->{'end_time'} && 
				( $thisItem->{'end_time'} >= $hiResTime || $thisItem->{'end_time'} == 0 )) {
				# This is in range (special case with 0 end_time)
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current playing $thisItem");
				
				if ( exists $perl_data->{'data'}->{'nowList'}[0]->{'mode'} && $perl_data->{'data'}->{'nowList'}[0]->{'mode'} eq 'song' ){
					$nowplaying = $thisItem;
					$info->{isSong} = true;
				}
				
				$calculatedPlaying->{$station}->{'progtitle'} = '';
				$calculatedPlaying->{$station}->{'progsubtitle'} = '';
				$calculatedPlaying->{$station}->{'progsynopsis'} = '';
				
				if (((!exists $thisItem->{'title'} || !defined($thisItem->{'title'}) || $thisItem->{'title'} eq '') && 
					exists $thisItem->{'subtitle'} && defined($thisItem->{'subtitle'}) && $thisItem->{'subtitle'} ne '' ) ||
				    exists $perl_data->{'data'}->{'nowList'}[0]->{'mode'} && $perl_data->{'data'}->{'nowList'}[0]->{'mode'} eq 'program' )
				{	# If there is no title but there is a subtitle ... or ... told explicitly that this is a programme ... then this is a show not a song
				
					main::DEBUGLOG && $log->is_debug && $log->debug("$station Found programme: ".$thisItem->{'subtitle'});
					
					if ( exists $thisItem->{'title'} && defined($thisItem->{'title'}) && $thisItem->{'title'} ne '' ){
						$calculatedPlaying->{$station}->{'progtitle'} = $thisItem->{'title'};
					} elsif ( exists $thisItem->{'subtitle'} && defined($thisItem->{'subtitle'}) && $thisItem->{'subtitle'} ne '' ) {
						$calculatedPlaying->{$station}->{'progtitle'} = $thisItem->{'subtitle'};
					}
					
					if (exists $thisItem->{'start_time'}){ $calculatedPlaying->{$station}->{'progstart'} = $thisItem->{'start_time'}};
					if (exists $thisItem->{'end_time'}){ $calculatedPlaying->{$station}->{'progend'} = $thisItem->{'end_time'}};
					
					if ( exists $thisItem->{'end_time'} && exists $thisItem->{'start_time'} ){
						# Work out programme duration and return if plausible
						$progDuration = $thisItem->{'end_time'} - $thisItem->{'start_time'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Show Duration $progDuration");
						
						if ($progDuration > 0) {$calculatedPlaying->{$station}->{'proglth'} = $progDuration};
					}

					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					
					my $thisartwork = '';
						
					$thisartwork = getcover($thisItem, $station, $info);

					$calculatedPlaying->{$station}->{'proglogo'} = $thisartwork;
					
					main::DEBUGLOG && $log->is_debug && $log->debug("Found show name in Type $dataType: $calculatedPlaying->{$station}->{'progtitle'}");
				} else {
					$nowplaying = $thisItem;
					$info->{isSong} = true;
				}
			}
			
			if ( $info->{isSong} ) {
			
				# $dumped =  Dumper $nowplaying;
				# $dumped =~ s/\n {44}/\n/g;   
				# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

				# main::DEBUGLOG && $log->is_debug && $log->debug("Time: ".time." Ends: ".$nowplaying->{'end_time'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current artist: ".$nowplaying->{'title'}." song: ".$nowplaying->{'subtitle'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$nowplaying->{'cover'});
				
				if (exists $nowplaying->{'start_time'}){ $calculatedPlaying->{$station}->{'songstart'} = $nowplaying->{'start_time'}};
				
				my $expectedEndTime = $hiResTime;
				
				if ( exists $nowplaying->{'end_time'} && $nowplaying->{'end_time'} > 0 ){ $expectedEndTime = $nowplaying->{'end_time'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

					if (exists $nowplaying->{'title'} && defined($nowplaying->{'title'}) && $nowplaying->{'title'} ne '') {
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'title'});
					}

					if (exists $nowplaying->{'subtitle'} && defined($nowplaying->{'subtitle'}) && $nowplaying->{'subtitle'} ne '') {$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($nowplaying->{'subtitle'})};

					$calculatedPlaying->{$station}->{'songyear'} = '';
					if (exists $nowplaying->{'year'} && defined($nowplaying->{'year'}) ) {
						$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'year'};
					}

					# Note - Label and Album are not available in the "playing_item" but are in "song"
					# Take year if it is present and have seen times when not present above
					if ( exists $songItem->{'year'} && defined($songItem->{'year'}) ) {$calculatedPlaying->{$station}->{'songyear'} = $songItem->{'year'}};
					
					$calculatedPlaying->{$station}->{'songlabel'} = '';
					if ( exists $songItem->{'label'} && defined( $songItem->{'label'} ) && $songItem->{'label'} ne '' ) {$calculatedPlaying->{$station}->{'songlabel'} = _lowercase($songItem->{'label'})};
					
					$calculatedPlaying->{$station}->{'songalbum'} = '';
					if (exists $songItem->{'album'} && defined( $songItem->{'album'} ) && $songItem->{'album'} ne '' ) {$calculatedPlaying->{$station}->{'songalbum'} = _lowercase($songItem->{'album'})};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					$thisartwork = getcover($nowplaying, $station, $info);
					
					if ($thisartwork eq ''){
						# Try to get it from the songItem instead
						$thisartwork = getcover($songItem, $station, $info);
					}

					if ($thisartwork ne ''){
						$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
					}
					
					if ( exists $nowplaying->{'end_time'} && exists $nowplaying->{'start_time'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'end_time'} - $nowplaying->{'start_time'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0) {$calculatedPlaying->{$station}->{'songlth'} = $songDuration};
					}
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$calculatedPlaying->{$station}->{'songend'} = $expectedEndTime;
					
				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("$station ($dataType) - Did not find Current Song in retrieved data");

			}
			
			#$dumped =  Dumper $calculatedPlaying->{$station};
			#$dumped =~ s/\n {44}/\n/g;   
			#main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");
		
		} elsif ( ref($perl_data) ne "ARRAY" && ( exists $perl_data->{'next'} && exists $perl_data->{'now'} && exists $perl_data->{'now'}->{'firstLine'}) ) {
			
			# {
				# "prev": [
					# {
						# "firstLine": "Le journal de 18h du week-end",
						# "firstLinePath": "emissions/le-journal-de-18h-du-week-end",
						# "firstLineUuid": "62ef9d9e-5f50-453e-b203-b246af89473f",
						# "secondLine": "Le journal de 18h du week-end du samedi 01 janvier 2022",
						# "secondLineUuid": "2344ef29-a78e-4246-b885-275522f52401",
						# "cover": "46e9712e-1f17-48a0-be48-ba772072eabe",
						# "startTime": 1641056400,
						# "endTime": 1641057050,
						# "contact": null
					# }
				# ],
				# "now": {
					# "firstLine": "Intelligence service",
					# "firstLinePath": "emissions/intelligence-service",
					# "firstLineUuid": "c8db814c-95b8-4103-9464-f1b41d26f4e8",
					# "secondLine": "Rousseau, juge de Jean-Jacques",
					# "secondLinePath": "emissions/intelligence-service/intelligence-service-du-samedi-01-janvier-2022",
					# "secondLineUuid": "6b5a612e-90f8-41bc-b225-11b19fbc738a",
					# "cover": "0cc20944-e1d7-431c-a104-88441857b1b7",
					# "startTime": 1641057050,
					# "endTime": 1641059999,
					# "contact": null
				# },
				# "next": [
					# {
						# "firstLine": "Le journal de 19h du week-end",
						# "firstLinePath": "emissions/le-journal-de-19h-du-week-end",
						# "firstLineUuid": "4eeac20f-9548-4e80-9aee-08cf6e5cc869",
						# "secondLine": "Le journal de 19h du week-end du samedi 01 janvier 2022",
						# "secondLinePath": "emissions/le-journal-de-19h-du-week-end/le-journal-de-19h-du-week-end-du-samedi-01-janvier-2022",
						# "secondLineUuid": "e9c2e35b-993a-48c6-bb1d-118f365170bc",
						# "cover": "eb180900-d537-4843-a00e-d172bf056074",
						# "startTime": 1641060000,
						# "endTime": 1641060970,
						# "contact": null
					# }
				# ],
				# "delayToRefresh": 1248000
			# }
			
			$dataType = 'rf4';
			my $nowplaying;
			my $thisItem;
			my $songItem;
			my $constructedsong;
			
			# Used to have only programme info - but appears to have been updated in  mid-2023 to include song info
			# "song": {
				# "id": "fed69b27-7ab3-4145-8084-44fde15166b4",
				# "year": 2019,
				# "release": {
					# "title": "Night sketches",
					# "label": "HALF AWAKE RECORDS"
				# }
			# }
			
			$thisItem = $perl_data->{'now'};
			
			#$dumped =  Dumper $thisItem;
			#$dumped =~ s/\n {44}/\n/g;
			#main::DEBUGLOG && $log->is_debug && $log->debug("$dataType: Now: $hiResTime thisItem: $dumped");
			
			if ( exists $thisItem->{'startTime'} && defined($thisItem->{'startTime'}) && $thisItem->{'startTime'} <= $hiResTime && 
				exists $thisItem->{'endTime'} && defined($thisItem->{'endTime'}) && 
				( $thisItem->{'endTime'} >= $hiResTime || $thisItem->{'endTime'} == 0 )) {
				# This is in range (special case with 0 end_time)
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current playing $thisItem");

				if ( exists $thisItem->{'song'} && $thisItem->{'song'} ){
					$nowplaying = $thisItem;
					$songItem = $thisItem->{'song'};
					$info->{isSong} = true;
				} elsif ( $guesssong && exists $thisItem->{'secondLine'} && defined($thisItem->{'secondLine'}) && ref($thisItem->{'secondLine'}) eq '' && $thisItem->{'secondLine'} ne '' ){
					# example - JULIEN CLERC \x{2022} This melody
					if ( $thisItem->{'secondLine'} =~ / \x{2022} / ){
						# Looks like this is really a song ... so take it and fake the data for later processing
						$thisItem->{'secondLine'} =~ m/^(?<artist>.*?) \x{2022} (?<title>.*)$/ms;
						
						if ( defined $+{'artist'} && $+{'artist'} ne '' && defined $+{'title'} && $+{'title'} ne '' ){

							my $a = $+{'artist'};
							my $t = $+{'title'};
							
							# check to see if should be ignored as possible song
							if ( defined $artistsignoreregex && $artistsignoreregex ne '' && $a =~ m/$artistsignoreregex/ ){
								main::DEBUGLOG && $log->is_debug && $log->debug("guessing not song: $thisItem->{'secondLine'}");
							} else {
								$constructedsong->{'secondLine'} = $a;
								$constructedsong->{'firstLine'} = $t;
								$constructedsong->{'startTime'} = $hiResTime;
								$nowplaying = $constructedsong;
								$songItem = $thisItem;
								$info->{isSong} = true;
								#$dumped = Data::Dump::dump($constructedsong);
								main::DEBUGLOG && $log->is_debug && $log->debug("guessing aong: $a - $t");
							}
						}
					}
				}
				
				$calculatedPlaying->{$station}->{'progtitle'} = '';
				$calculatedPlaying->{$station}->{'progsubtitle'} = '';
				$calculatedPlaying->{$station}->{'progsynopsis'} = '';
				
				if ( !$info->{isSong} ){
					if ( ( exists $thisItem->{'firstLine'} && defined($thisItem->{'firstLine'}) && $thisItem->{'firstLine'} ne '') || 
						 ( exists $thisItem->{'secondLine'} && defined($thisItem->{'secondLine'}) && $thisItem->{'secondLine'} ne '' ) ) {
						# firstLine (title) and/or secondLine (subtitle)
					
						main::DEBUGLOG && $log->is_debug && $log->debug("$station Found programme: ".$thisItem->{'firstLine'});
						
						if ( exists $thisItem->{'firstLine'} && defined($thisItem->{'firstLine'}) && ref($thisItem->{'firstLine'}) eq 'HASH' && 
							 exists $thisItem->{'firstLine'}->{'title'} && defined($thisItem->{'firstLine'}->{'title'}) && $thisItem->{'firstLine'}->{'title'} ne '' ){
							$calculatedPlaying->{$station}->{'progtitle'} = _trim( $thisItem->{'firstLine'}->{'title'} );
						} elsif ( exists $thisItem->{'firstLine'} && defined($thisItem->{'firstLine'}) && $thisItem->{'firstLine'} ne '' ){
							$calculatedPlaying->{$station}->{'progtitle'} = _trim( $thisItem->{'firstLine'} );
						} 

						if ( exists $thisItem->{'secondLine'} && defined($thisItem->{'secondLine'}) && ref($thisItem->{'secondLine'}) eq 'HASH' && 
						     exists $thisItem->{'secondLine'}->{'title'} && defined($thisItem->{'secondLine'}->{'title'}) && $thisItem->{'secondLine'}->{'title'} ne '' &&
							 _trim($thisItem->{'secondLine'}->{'title'}) ne $calculatedPlaying->{$station}->{'progtitle'} ) {
							$calculatedPlaying->{$station}->{'progsubtitle'} = _trim( $thisItem->{'secondLine'}->{'title'} );
						} elsif ( exists $thisItem->{'secondLine'} && defined($thisItem->{'secondLine'}) && $thisItem->{'secondLine'} ne '' &&
							 _trim($thisItem->{'secondLine'}) ne $calculatedPlaying->{$station}->{'progtitle'} ) {
							$calculatedPlaying->{$station}->{'progsubtitle'} = _trim( $thisItem->{'secondLine'} );
						}
						
						if (exists $thisItem->{'intro'}){ $calculatedPlaying->{$station}->{'progsynopsis'} = _trim( $thisItem->{'intro'} )};

						if (exists $thisItem->{'startTime'}){ $calculatedPlaying->{$station}->{'progstart'} = $thisItem->{'startTime'}};
						if (exists $thisItem->{'endTime'}){ $calculatedPlaying->{$station}->{'progend'} = $thisItem->{'endTime'}};

						if ( exists $thisItem->{'endTime'} && exists $thisItem->{'startTime'} ){
							# Work out programme duration and return if plausible
							$progDuration = $thisItem->{'endTime'} - $thisItem->{'startTime'};
							
							# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Show Duration $progDuration");
							
							if ($progDuration > 0) {$calculatedPlaying->{$station}->{'proglth'} = $progDuration};
						}

						my $programmePath = '';
						if ( exists $thisItem->{'secondLinePath'} && defined($thisItem->{'secondLinePath'}) && $thisItem->{'secondLinePath'} ne '' ){
							$programmePath = $thisItem->{'secondLinePath'};
						}

						# Seen example where secondLinePath points to the set of shows rather than the specific
						# but the array secondLinePaths had the real one ... but which ... try the longest
						# Example:
						# "secondLinePath": "francemusique/podcasts/disques-de-legende",
						# "secondLinePaths": [
							# "francemusique/podcasts/disques-de-legende",
							# "francemusique/podcasts/disques-de-legende/disques-de-legende-du-mercredi-29-juin-2022-3753240"
						# ],
						if ( exists $thisItem->{'secondLinePaths'} && ref( $thisItem->{'secondLinePaths'} ) eq "ARRAY" ){
							foreach my $tryPath ( @{$thisItem->{'secondLinePaths'}} ){
								if ( length $tryPath > length $programmePath ){
									$programmePath = $tryPath;
								}
							}
						}
						
						if ( $programmePath ne '' ){
							# Path exists ... which might mean that song data is available
							&getindividualprogrammemeta( $client, $url, $programmePath );
						}
						# Artwork - only include if not one of the defaults - to give chance for something else to add it
						# Regex check to see if present using $iconsIgnoreRegex

						my $thisartwork = '';

						$thisartwork = getcover($thisItem, $station, $info);

						$calculatedPlaying->{$station}->{'proglogo'} = $thisartwork;

						#main::DEBUGLOG && $log->is_debug && $log->debug("Found show name in Type $dataType: $calculatedPlaying->{$station}->{'progtitle'}");
					}
				}
				
				if ( $info->{isSong} ) {
			
					# $dumped =  Dumper $nowplaying;
					# $dumped =~ s/\n {44}/\n/g;   
					# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

					# main::DEBUGLOG && $log->is_debug && $log->debug("Time: ".time." Ends: ".$nowplaying->{'end_time'});
					# main::DEBUGLOG && $log->is_debug && $log->debug("Current artist: ".$nowplaying->{'title'}." song: ".$nowplaying->{'subtitle'});
					# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$nowplaying->{'cover'});
					
					if (exists $nowplaying->{'startTime'}){ $calculatedPlaying->{$station}->{'songstart'} = $nowplaying->{'startTime'}};
					
					my $expectedEndTime = $hiResTime;
					
					if ( exists $nowplaying->{'endTime'} && $nowplaying->{'endTime'} > 0 ){ $expectedEndTime = $nowplaying->{'endTime'}};
					
					if ( $expectedEndTime > $hiResTime-30 ){
						# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
						# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

						if (exists $nowplaying->{'secondLine'} && defined($nowplaying->{'secondLine'}) && $nowplaying->{'secondLine'} ne '') {
							if ( ref($nowplaying->{'secondLine'}) eq 'HASH' && exists $nowplaying->{'secondLine'}->{'title'} && $nowplaying->{'secondLine'}->{'title'} ne '' ){
								$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'secondLine'}->{'title'});
							} else {
								$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'secondLine'});
							}
						}

						if (exists $nowplaying->{'firstLine'} && defined($nowplaying->{'firstLine'}) && $nowplaying->{'firstLine'} ne '') {
							if ( ref($nowplaying->{'firstLine'}) eq 'HASH' && $nowplaying->{'firstLine'}->{'title'} && $nowplaying->{'firstLine'}->{'title'} ne '' ){
								$calculatedPlaying->{$station}->{'songtitle'} = $nowplaying->{'firstLine'}->{'title'}
							} else {
								$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($nowplaying->{'firstLine'});
							}
						}

						$calculatedPlaying->{$station}->{'songyear'} = '';
						if (exists $nowplaying->{'year'} && defined($nowplaying->{'year'}) ) {
							$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'year'};
						}

						# Note - Label and Album are not available in the "playing_item" but are in "song"
						# Take year if it is present and have seen times when not present above
						if ( exists $songItem->{'year'} && defined($songItem->{'year'}) ) {$calculatedPlaying->{$station}->{'songyear'} = $songItem->{'year'}};
						
						$calculatedPlaying->{$station}->{'songlabel'} = '';
						if ( exists $songItem->{'release'} && exists $songItem->{'release'}->{'label'} && defined( $songItem->{'release'}->{'label'} ) && $songItem->{'release'}->{'label'} ne '' ) {$calculatedPlaying->{$station}->{'songlabel'} = _lowercase($songItem->{'release'}->{'label'})};
						
						$calculatedPlaying->{$station}->{'songalbum'} = '';
						if (exists $songItem->{'release'} && exists $songItem->{'release'}->{'title'} && defined( $songItem->{'release'}->{'title'} ) && $songItem->{'release'}->{'title'} ne '' ) {$calculatedPlaying->{$station}->{'songalbum'} = _lowercase($songItem->{'release'}->{'title'})};
						
						# Artwork - only include if not one of the defaults - to give chance for something else to add it
						# Regex check to see if present using $iconsIgnoreRegex
						my $thisartwork = '';
						
						$thisartwork = getcover($nowplaying, $station, $info);
						
						if ($thisartwork eq ''){
							# Try to get it from the songItem instead
							$thisartwork = getcover($songItem, $station, $info);
						}

						if ($thisartwork ne ''){
							$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
						}
						
						if ( exists $nowplaying->{'endTime'} && exists $nowplaying->{'startTime'} ){
							# Work out song duration and return if plausible
							$songDuration = $nowplaying->{'endTime'} - $nowplaying->{'startTime'};
							
							# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
							
							if ($songDuration > 0) {$calculatedPlaying->{$station}->{'songlth'} = $songDuration};
						}
						
						# Try to update the predicted end time to give better chance for timely display of next song
						$calculatedPlaying->{$station}->{'songend'} = $expectedEndTime;
						
					} else {
						# This song that is playing should have already finished so returning largely blank data should reset what is displayed
						main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
					}
				}
			}			
		} elsif ( ref($perl_data) ne "ARRAY" && 
			  ( exists $perl_data->{'content'} && exists $perl_data->{'content'}->{'songs'} && ref($perl_data->{'content'}->{'songs'}) eq "ARRAY" ) ||
			  (  exists $perl_data->{'songs'} && ref($perl_data->{'songs'}) eq "ARRAY" ) ) {
			# France Musique podcast type json
			# "https://www.radiofrance.fr/api/v1.7/path?value=francemusique/podcasts/allegretto/allegretto-du-mercredi-29-juin-2022-3801081"
			# or an alternative version that only has the songs array
			# https://www.radiofrance.fr/api/v1.7/stations/francemusique/songs?pageCursor=Mg%3D%3D&startDate=1656507600&endDate=1656514680&isPad=false
			# Sample Response
			# {
				# "content": {
					# "type": "Expression",
					# "id": "da42670b-5cb8-4ac7-848f-e5b503527fcb",
					# "title": "Bach part en vacances",
					# "seoTitle": "",
					# "seoDescription": "",
					# "stationIds": [
						# 4
					# ],
					# "kind": "episode",
					# "path": "francemusique/podcasts/allegretto/allegretto-du-mercredi-29-juin-2022-3801081",
					# "migrated": true,
					# "standFirst": "Avec Bartok, Dave Brubeck, Mozart, Richard Morton Sherman, Jethro Tull, Lalo Schiffrin...",
					# "isPad": false,
					# "place": null,
					# "latestRediffusion": null,
					# "bodyJson": [
						# {
							# "type": "heading",
							# "level": 3,
							# "value": "Des places à gagner"
						# },
						# {
							# "type": "text",
							# "children": [
								# {
									# "type": "text",
									# "value": "<strong>Pour tenter de gagner deux places, c'est ici :</strong> \" "
								# },
								# {
									# "type": "link",
									# "data": {
										# "href": "https://www.radiofrance.fr/francemusique/contact/formulaire?concept=23813bbb-82bf-46a7-99f8-336b01019095"
									# },
									# "value": "Contactez l'émission"
								# },
								# {
									# "type": "text",
									# "value": " \""
								# }
							# ]
						# },
						# {
							# "type": "heading",
							# "level": 3,
							# "value": "Quelle musique entendez-vous sur \" Ouessant, côte nord-est \" ?"
						# },
						# {
							# "type": "image",
							# "data": {
								# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/f45163f6-fd00-4799-a347-8472f954d645/860_meheut.jpg",
								# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/f45163f6-fd00-4799-a347-8472f954d645/860_meheut.webp",
								# "width": 860,
								# "height": 483,
								# "ratio": "56.16279069767442%",
								# "alt": "Mathurin Méheut (1882-1958), Ouessant, côte nord-est. Gouache et fusain sur carton, H. 49 ; l. 64 cm. Musée Mathurin Méheut, Lamballe-Armor",
								# "preview": "data:image/jpeg;charset=utf-8;base64, /9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAXACoDASIAAhEBAxEB/8QAGAABAQEBAQAAAAAAAAAAAAAABAADAgH/xAAiEAACAgIABgMAAAAAAAAAAAAAAQIRBSEDBBIxQXFCUWH/xAAWAQADAAAAAAAAAAAAAAAAAAAAAQL/xAAVEQEBAAAAAAAAAAAAAAAAAAAAAf/aAAwDAQACEQMRAD8AfzrpRCapsTkPgFT1RNNm3L8OW3s0qzKUHepAD8W74c/Y4DjFUJ+xxUITnlqLvsDS8kRNOOWurzR4opd9kQA/H10Sr7FkRUJ//9k=",
								# "sizes": "(max-width: 480px) 200px, (max-width: 1024px) 1000px, 2000px",
								# "srcset": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/f45163f6-fd00-4799-a347-8472f954d645/860_meheut.jpg 860w",
								# "webpSrcset": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/f45163f6-fd00-4799-a347-8472f954d645/860_meheut.webp 860w",
								# "copyright": null,
								# "author": "© Musée Mathurin Méheut, Lamballe-Armor / ADAGP, Paris 2022"
							# }
						# },
						# {
							# "type": "list",
							# "ordered": false,
							# "children": [
								# {
									# "type": "list_item",
									# "children": [
										# {
											# "type": "text",
											# "value": "<strong>Allegretto vous propose de participer à la programmation musicale du vendredi 1er juillet en vous inspirant de ce tableau de Mathurin Méheut visible dans l'exposition</strong> "
										# },
										# {
											# "type": "link",
											# "data": {
												# "href": "https://www.radiofrance.fr/francemusique/quelle-musique-entendez-vous-sur-ouessant-cote-nord-est-4584610"
											# },
											# "value": "<em>Mathurin Méheut Arpenteur de la Bretagne</em>"
										# },
										# {
											# "type": "text",
											# "value": " <strong>jusqu'au 31 décembre au Musée de Pont-Aven.</strong>"
										# }
									# ]
								# }
							# ]
						# },
						# {
							# "type": "text",
							# "children": [
								# {
									# "type": "text",
									# "value": "<strong>Pour vos propositions, c'est ici :</strong> \" "
								# },
								# {
									# "type": "link",
									# "data": {
										# "href": "https://www.radiofrance.fr/francemusique/contact/formulaire?concept=23813bbb-82bf-46a7-99f8-336b01019095"
									# },
									# "value": "Contactez l'émission"
								# },
								# {
									# "type": "text",
									# "value": " \""
								# }
							# ]
						# }
					# ],
					# "startDate": 1656493200,
					# "endDate": 1656498510,
					# "guest": [],
					# "serie": null,
					# "visual": {
						# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/560x315_arnstadt.jpg",
						# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/560x315_arnstadt.webp",
						# "legend": "Gravure de la ville d' Arnstadt où JS Bach vécu de 1703 à 1707 ©Getty - Culture Club/Getty Images",
						# "copyright": "Getty",
						# "author": "Culture Club/Getty Images",
						# "width": 560,
						# "height": 315,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAXACoDASIAAhEBAxEB/8QAGAAAAwEBAAAAAAAAAAAAAAAAAAMFBAH/xAAiEAACAgAGAgMAAAAAAAAAAAAAAQIRAwQFEiExNFEiQnH/xAAWAQEBAQAAAAAAAAAAAAAAAAABAgD/xAAVEQEBAAAAAAAAAAAAAAAAAAAAAf/aAAwDAQACEQMRAD8Ap5x1l5USYTkpP50inqHiTJCVUFY6M6k+Xfs7LEffLFxpO93B2LTl2SW/TsRzU7XRtMWnff0bSoCc348uLJD2ppKwAKTHBRX6Kdb1wABApae7jI2ABUZ//9k="
					# },
					# "visual_400x400": {
						# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/400x400_arnstadt.jpg",
						# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/400x400_arnstadt.webp",
						# "legend": "Gravure de la ville d' Arnstadt où JS Bach vécu de 1703 à 1707",
						# "copyright": "Getty",
						# "author": "Culture Club/Getty Images",
						# "width": 400,
						# "height": 400,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGAAAAwEBAAAAAAAAAAAAAAAAAQIDBAD/xAAmEAACAgEDAwMFAAAAAAAAAAABAgARAxIhMQQTUSJBcTIzQmGh/8QAFgEBAQEAAAAAAAAAAAAAAAAAAQAC/8QAFxEBAQEBAAAAAAAAAAAAAAAAABEBMf/aAAwDAQACEQMRAD8A7H1jUQw39qlD1TMNgRMqaVa7lWZSgvk8TO7qUx5MirbUY5z6gbNzNjcj0jmNqYD9Suo4bmuY/fmdtVWhqTvJ5/kK1cAaQTYjkHTsu1Tit2a28wBjd77SZFGP4rcZiQsAdiO4oo/EUsxNsLklFs0SQRH0DzJYsg0laO3Erov2MKk3xgelXBHzG0O2MGhqG23iZmE0dKTfMeGHN1pJryJNm4IHEpl+5IniGAcf1FhtcPcPl5EcmVjBX//Z"
					# },
					# "visual_1000x563": {
						# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/1000x563_arnstadt.jpg",
						# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/1000x563_arnstadt.webp",
						# "legend": "Gravure de la ville d' Arnstadt où JS Bach vécu de 1703 à 1707",
						# "copyright": "Getty",
						# "author": "Culture Club/Getty Images",
						# "width": 1000,
						# "height": 563,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAXACoDASIAAhEBAxEB/8QAGAAAAwEBAAAAAAAAAAAAAAAAAAMFBAH/xAAhEAACAgEDBQEAAAAAAAAAAAAAAQIRBQQhMQMSIjRRcf/EABYBAQEBAAAAAAAAAAAAAAAAAAECAP/EABURAQEAAAAAAAAAAAAAAAAAAAAB/9oADAMBAAIRAxEAPwCnrHWnkSYTkpPzpFPIepIkJVQVjozqT3d/Tsuo+d2LVJ33bHYtOXJJb8d1HNTtcG0xY7mfw2lQE6z15bWSG4JpJsACkxwUF+im13q0ABApY93GRsACoz//2Q=="
					# },
					# "visual_2048x640": {
						# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/2048x640_arnstadt.jpg",
						# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/2048x640_arnstadt.webp",
						# "legend": "Gravure de la ville d' Arnstadt où JS Bach vécu de 1703 à 1707",
						# "copyright": "Getty",
						# "author": "Culture Club/Getty Images",
						# "width": 1280,
						# "height": 400,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAANACoDASIAAhEBAxEB/8QAGAAAAwEBAAAAAAAAAAAAAAAAAgQFAAP/xAAhEAACAQQBBQEAAAAAAAAAAAAAAQIEESFRBQMiMTJBQv/EABYBAQEBAAAAAAAAAAAAAAAAAAACAf/EABYRAQEBAAAAAAAAAAAAAAAAAAABMf/aAAwDAQACEQMRAD8ApVrtSzZHhJp3wWK5XpZojfm+iaDUu5vwE84yc1J52vplNqe7mChxkbPqD4lx69nsdKmD/9k="
					# },
					# "squaredVisual": {
						# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/400x400_arnstadt.jpg",
						# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/400x400_arnstadt.webp",
						# "legend": "Gravure de la ville d' Arnstadt où JS Bach vécu de 1703 à 1707",
						# "copyright": "Getty",
						# "author": "Culture Club/Getty Images",
						# "width": 400,
						# "height": 400,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGAAAAwEBAAAAAAAAAAAAAAAAAQIDBAD/xAAmEAACAgEDAwMFAAAAAAAAAAABAgARAxIhMQQTUSJBcTIzQmGh/8QAFgEBAQEAAAAAAAAAAAAAAAAAAQAC/8QAFxEBAQEBAAAAAAAAAAAAAAAAABEBMf/aAAwDAQACEQMRAD8A7H1jUQw39qlD1TMNgRMqaVa7lWZSgvk8TO7qUx5MirbUY5z6gbNzNjcj0jmNqYD9Suo4bmuY/fmdtVWhqTvJ5/kK1cAaQTYjkHTsu1Tit2a28wBjd77SZFGP4rcZiQsAdiO4oo/EUsxNsLklFs0SQRH0DzJYsg0laO3Erov2MKk3xgelXBHzG0O2MGhqG23iZmE0dKTfMeGHN1pJryJNm4IHEpl+5IniGAcf1FhtcPcPl5EcmVjBX//Z"
					# },
					# "producers": [
						# {
							# "id": "192bc212-a71c-4de0-b339-c5b3838c1b79",
							# "name": "Denisa Kerschova",
							# "path": "personnes/denisa-kerschova",
							# "migrated": true,
							# "visual": {
								# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/03/8b75a339-396c-4dc5-87bd-2fbd6ee1d3b5/120x120_keschova-15763-19-0051-1280x720.jpg",
								# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/03/8b75a339-396c-4dc5-87bd-2fbd6ee1d3b5/120x120_keschova-15763-19-0051-1280x720.webp",
								# "legend": "Denisa Kerschova",
								# "copyright": "Radio France",
								# "author": "Christophe Abramowitz",
								# "width": 120,
								# "height": 120,
								# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGQAAAwEBAQAAAAAAAAAAAAAAAAQFAwIG/8QAJRAAAQQBBAIBBQAAAAAAAAAAAQACAxEEBRIhMRNBURUiMjRy/8QAFwEBAQEBAAAAAAAAAAAAAAAAAgABA//EABkRAQEAAwEAAAAAAAAAAAAAAAABAhEhMf/aAAwDAQACEQMRAD8AspPNynRODI63H5Tik6kzbkh+78h0srY6gzMjyDyUWqjE/wAjbqlPiY3xA9lP44qIWslblNNEIQkIUrVg0Stc6x6v0qqja7e+P4pSjoS3AOrHsJyHIO5oNbaXnmSuZ0eFT097ntc53DAjrR8yWQbCFjBJyWHg9hbJAEjquMJoN90WJ5Y5f6sn8qSONOaYNwdbz0mHNEQixme+XLvA5galnk/VByj7XS86sRt+1pIHAWiB0hJzf//Z"
							# },
							# "role": "production"
						# }
					# ],
					# "staff": [
						# {
							# "id": "44fb935c-fd36-4ff4-86c4-f3547bf995ee",
							# "name": "Arnaud Chappatte",
							# "path": "personnes/arnaud-chappatte",
							# "migrated": true,
							# "visual": null,
							# "role": "realisation"
						# },
						# {
							# "id": "4c644ffa-c13b-40cd-bf3a-ed775287791b",
							# "name": "Laurent Lefrançois",
							# "path": "personnes/laurent-lefrancois",
							# "migrated": true,
							# "visual": {
								# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2016/04/fa423c2e-3815-4b31-850f-6877c5dedc0f/120x120_lefrancois_149x185.jpg",
								# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2016/04/fa423c2e-3815-4b31-850f-6877c5dedc0f/120x120_lefrancois_149x185.webp",
								# "legend": "Laurent Lefrançois © okarinamusique.com",
								# "copyright": null,
								# "author": null,
								# "width": 120,
								# "height": 120,
								# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGQAAAwEBAQAAAAAAAAAAAAAAAgMEAQUA/8QAIxAAAgICAgIBBQAAAAAAAAAAAAECAxEhBDEiURMSMjNhcf/EABYBAQEBAAAAAAAAAAAAAAAAAAIBA//EABcRAQEBAQAAAAAAAAAAAAAAAAABETH/2gAMAwEAAhEDEQA/ADFWz8lFDCa7VrZmcVVZ1oo+lWQaxpkvFnZZGcXr0U8ZTWpPoNNHW3Vc4PoqNsqipSk0CIKSBbHKT9BGlRlc1C30mWwbck10c3K+bCekdOheKwCnpPKbdiinhdg5GcleS/gkUGl4eBc3LGmPEz6ZUDXXnfs6XHSrhtkFP5Uv0UyekSlOGxkrpy9dID4T3E+5lBUf/9k="
							# },
							# "role": "realisation"
						# },
						# {
							# "id": "93942217-e716-4229-89fc-6f1bfa8a075b",
							# "name": "Maud Noury",
							# "path": "personnes/maud-noury",
							# "migrated": true,
							# "visual": null,
							# "role": "collaboration"
						# }
					# ],
					# "composer": [],
					# "conductor": [],
					# "orchestra": [],
					# "choir": [],
					# "choirmaster": [],
					# "soloist": [],
					# "themes": [
						# {
							# "id": "c495dd3c-4a42-4ac9-bcde-78c325bef412",
							# "title": "Musiques et actualité musicale",
							# "migrated": true,
							# "path": "musique",
							# "parent": null
						# },
						# {
							# "id": "deee56fd-dd7c-4ef8-b51e-236778faaa75",
							# "title": "Musique classique",
							# "migrated": true,
							# "path": "musique/classique",
							# "parent": {
								# "id": "c495dd3c-4a42-4ac9-bcde-78c325bef412",
								# "title": "Musiques et actualité musicale",
								# "path": "musique",
								# "parent": null
							# }
						# }
					# ],
					# "tagsAndPersonalities": [
						# {
							# "id": "eb3bf11e-a4e4-4050-9a9f-2bd2a43e71fa",
							# "title": "Programmation musicale",
							# "path": "sujets/programmation-musicale",
							# "migrated": true
						# },
						# {
							# "id": "9522ccdc-86c8-42a1-96dc-0a887b7b545e",
							# "path": "personnes/johann-sebastian-bach",
							# "migrated": true,
							# "title": "Jean-Sébastien Bach"
						# }
					# ],
					# "concept": {
						# "podcast": {
							# "rss": "https://radiofrance-podcast.net/podcast09/rss_14497.xml",
							# "itune": {
								# "url": "https://podcasts.apple.com/fr/podcast/allegretto-programme-musical-de-denisa-kerschova/id1037705293"
							# }
						# },
						# "id": "23813bbb-82bf-46a7-99f8-336b01019095",
						# "title": "Allegretto",
						# "path": "francemusique/podcasts/allegretto",
						# "visual": {
							# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2021/11/d4bc9ce0-c767-4940-a287-4792333fb553/120x120_fm-allegretto.jpg",
							# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2021/11/d4bc9ce0-c767-4940-a287-4792333fb553/120x120_fm-allegretto.webp",
							# "legend": "visuel  podcast  Allegretto",
							# "copyright": "Radio France",
							# "author": "Christophe Abramowitz - DN",
							# "width": 120,
							# "height": 120,
							# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGQAAAwEBAQAAAAAAAAAAAAAAAQQFAgMA/8QAJBAAAQQBBAEFAQAAAAAAAAAAAQACAxEEEiExUUETFCNScZH/xAAYAQADAQEAAAAAAAAAAAAAAAAAAQIDBP/EABwRAQEAAQUBAAAAAAAAAAAAAAABMQIDERITYf/aAAwDAQACEQMRAD8AoNC08iOMuPgItC9MPgf+JgpBlvkfuwaTxScI2Kl4szWtaLBo7qqxwkbYUynYhSxP1uOna1z0O6KvGCP6rHt4/qqbTedWoyN1xOaPIpBpXGXMbE5zdJJCGEluEhmHKH2TQB3VjEssDhxwpRM59SiKeb/E9jZbIoWx6TY5SX1vGD5WUbsA9rNpoJtz4R5KDpsZ9uLTZ8qUt2eyh0+UmALJy46bq9lQxzCIm+pGdY5SQca5K9qd2f6gdPqmc+EbWRSHv4eypLuSggeOl//Z"
						# },
						# "connections": [
							# {
								# "type": "mail",
								# "title": null,
								# "url": "Maud.NOURY@radiofrance.com"
							# },
							# {
								# "type": "mail",
								# "title": null,
								# "url": "Denisa.KERSCHOVA@radiofrance.com"
							# },
							# {
								# "type": "mail",
								# "title": null,
								# "url": "allegretto@radiofrance.com"
							# },
							# {
								# "type": "mail",
								# "title": null,
								# "url": "Come.JOCTEUR-MONROZIER@radiofrance.com"
							# }
						# ]
					# },
					# "manifestations": [],
					# "videos": [],
					# "mainResource": null,
					# "interpretations": [],
					# "concerts": [],
					# "authors": [],
					# "manualUpdate": 1656493200,
					# "publishedDate": 1656493200,
					# "songs": [
						# {
							# "id": "ce67ff9a-e35d-4575-b109-0804cb72c9fd",
							# "firstLine": "Jean-Sébastien Bach (Compositeur), Dimitri Naiditch (Compositeur)",
							# "secondLine": "Suite n°2 en si min BWV 1067 : Badinerie",
							# "thirdLine": 2019,
							# "interpreters": [
								# "Jean-Sébastien Bach (Compositeur)",
								# "Dimitri Naiditch (Compositeur)",
								# "Dimitri Naïditch (Piano)",
								# "Gilles Naturel (Contrebasse)",
								# "Arthur Alard (Batterie)",
								# "Dimitri Naïditch"
							# ],
							# "release": {
								# "year": 2019,
								# "title": "Bach Up.",
								# "label": "Dinaï",
								# "reference": null
							# },
							# "visual": {
								# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2019/09/f5e573ed-0147-408e-ac1b-2989a9f96ce1/200x200_rf_omm_0001799327_dnc.0087193924.jpg",
								# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2019/09/f5e573ed-0147-408e-ac1b-2989a9f96ce1/200x200_rf_omm_0001799327_dnc.0087193924.webp",
								# "legend": null,
								# "copyright": null,
								# "author": null,
								# "width": 200,
								# "height": 200,
								# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAFwAAAwEAAAAAAAAAAAAAAAAAAwQFAv/EACYQAAEEAQQCAAcAAAAAAAAAAAEAAgMREgQhMUETIhQyNFFScZH/xAAWAQEBAQAAAAAAAAAAAAAAAAACAQD/xAAZEQEBAQEBAQAAAAAAAAAAAAAAARFBAiH/2gAMAwEAAhEDEQA/AHHyP8+AdW63qJPFDlybQXfUg9WtTyMwaHnYnhGdP1xmKQyBtkndDMLHEk82lJNW6A4xne1vT6kyZZVa3Bub8bmjAitp2BTrHejf0kRG6R4s009Jr4Z35lKXBs0SWNrng7JDWyBkkZ+wNKg5zW2TVAbqHqZvNLfQ4UK2guJcST2j6V2MnF7IHaPEMZxS1RS05Jd7cp+lPhPuNtyVQRhUhqXMwcXmrUc0CUxrifPVpYpi0xpc4AC1Wgiui5oxU3TcOR4nOv5j/VKsuKOLGmwCjZpVhJG5RlMZ/9k="
							# },
							# "links": [],
							# "start": "1656493197",
							# "end": "1656493471"
						# },
						# {
							# "id": "81391cc3-4566-494d-a80f-2e2f85ddf9be",
							# "firstLine": "Jean Sebastien Bach (Compositeur)",
							# "secondLine": "L'art de la fugue bwv 1080 : contrapunctus I",
							# "thirdLine": 1985,
							# "interpreters": [
								# "Canadian Brass"
							# ],
							# "release": {
								# "year": 1985,
								# "title": "Best of the Canadian brass",
								# "label": "CBS",
								# "reference": "MK 45744"
							# },
							# "visual": {
								# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2019/12/7edae92b-4249-43da-9cca-457ba953de4a/200x200_rf_omm_0000353440_dnc.0054252708.jpg",
								# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2019/12/7edae92b-4249-43da-9cca-457ba953de4a/200x200_rf_omm_0000353440_dnc.0054252708.webp",
								# "legend": null,
								# "copyright": null,
								# "author": null,
								# "width": 200,
								# "height": 200,
								# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGAABAQEBAQAAAAAAAAAAAAAABAMCAQD/xAAlEAABBAEDBQADAQAAAAAAAAABAAIDEQQSITMiIzEyQUJRcYH/xAAWAQEBAQAAAAAAAAAAAAAAAAABAAL/xAAVEQEBAAAAAAAAAAAAAAAAAAAAAf/aAAwDAQACEQMRAD8ALHFHpYa3IWZG6DRWo3M0N6hdKc03VpABv6slprqF1YWm04W4EH4oXojc113exSYxTRbrtJQyB0IqblDtlCTGa3F7FeHvZ8LsXssv2cVImWPU0vDumt1lrnOa0D54XIHF0T2HxS9jAl42/wBQ0vljsoKblntkIKWarj8ipLB+V0FPH5Qly8ZUg43aA4fsK2JG7k+eEVNwvR39UXcodslCTsviQVCv/9k="
							# },
							# "links": [],
							# "start": "1656493544",
							# "end": "1656493701"
						# }
					# ],
					# "songsCursor": null,
					# "isTimeshiftable": true,
					# "background": {
						# "src": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/2048x640_arnstadt.jpg",
						# "webpSrc": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/2048x640_arnstadt.webp",
						# "legend": "Gravure de la ville d' Arnstadt où JS Bach vécu de 1703 à 1707",
						# "copyright": "Getty",
						# "author": "Culture Club/Getty Images",
						# "width": 1280,
						# "height": 400,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAANACoDASIAAhEBAxEB/8QAGAAAAwEBAAAAAAAAAAAAAAAAAgQFAAP/xAAhEAACAQQBBQEAAAAAAAAAAAAAAQIEESFRBQMiMTJBQv/EABYBAQEBAAAAAAAAAAAAAAAAAAACAf/EABYRAQEBAAAAAAAAAAAAAAAAAAABMf/aAAwDAQACEQMRAD8ApVrtSzZHhJp3wWK5XpZojfm+iaDUu5vwE84yc1J52vplNqe7mChxkbPqD4lx69nsdKmD/9k=",
						# "srcset": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/400x400_arnstadt.jpg 400w, https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/1000x563_arnstadt.jpg 1000w, https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/2048x640_arnstadt.jpg 2048w",
						# "webpSrcset": "https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/400x400_arnstadt.webp 400w, https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/1000x563_arnstadt.webp 1000w, https://cdn.radiofrance.fr/s3/cruiser-production/2022/06/a089496b-0608-42ea-ac69-a7e1990ccaf8/2048x640_arnstadt.webp 2048w"
					# },
					# "timeshiftStreams": []
				# }
			# }

			$dataType = 'rf5';
			my $nowplaying;
			my $parentItem = '';
			my $thisItem;
			
			# Try to find what is playing (priority to song over programme)

			my @items = ();
			# songs[] seems to have a maximum of 10 items - after that need to use pageCursor with different URL
			if ( exists $perl_data->{'songs'} && ref($perl_data->{'songs'}) eq "ARRAY" ){
				$dataType = $dataType.'b';
				@items = @{ $perl_data->{'songs'} };
				#$dumped =  Dumper @items;
				#main::DEBUGLOG && $log->is_debug && $log->debug("songs: $dumped");
			} else {
				@items = @{ $perl_data->{'content'}->{'songs'} };
			}
				
			# $dumped =  Dumper @levels;
			# print $dumped;

			foreach my $thisItem ( @items ){
				# main::DEBUGLOG && $log->is_debug && $log->debug("item: $thisItem");
				
				if ( exists $thisItem->{'start'} && $thisItem->{'start'} <= $hiResTime && 
					exists $thisItem->{'end'} && $thisItem->{'end'} >= $hiResTime &&
					!$info->{isSong}) {
					# This one is in range and not already found a song (might have found a programme or segment but song trumps it)
					# main::DEBUGLOG && $log->is_debug && $log->debug("Current playing $item");
					if ((exists $thisItem->{'firstLine'} && $thisItem->{'firstLine'} ne '' ) ||
					    $thisItem->{'end'} - $thisItem->{'start'} <= maxSongLth ) {
						$nowplaying = $thisItem;
						$info->{isSong} = true;
					}
				} else {
					if ( exists $thisItem->{'start'} && exists $thisItem->{'end'} ){
						#main::DEBUGLOG && $log->is_debug && $log->debug("Now: $hiResTime, Start: $thisItem->{'start'}, End: $thisItem->{'end'}");
					}
				}
			}		
			
			if ( $info->{isSong} ) {
			
				# $dumped =  Dumper $nowplaying;
				# $dumped =~ s/\n {44}/\n/g;   
				# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

				# main::DEBUGLOG && $log->is_debug && $log->debug("Time: ".time." Ends: ".$nowplaying->{'end'});
				
				if (exists $nowplaying->{'start'}){ $calculatedPlaying->{$station}->{'songstart'} = $nowplaying->{'start'}};
				
				my $expectedEndTime = $hiResTime;
				
				if (exists $nowplaying->{'end'}){ $expectedEndTime = $nowplaying->{'end'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

					$calculatedPlaying->{$station}->{'songartist'} = '';
					if ( exists $nowplaying->{'firstLine'} && $nowplaying->{'firstLine'} ne '' ) {
						$calculatedPlaying->{$station}->{'songartist'} = $nowplaying->{'firstLine'};
					}
					
					$calculatedPlaying->{$station}->{'songtitle'} = '';
					if (exists $nowplaying->{'secondLine'} && $nowplaying->{'secondLine'} ne ''){
						$calculatedPlaying->{$station}->{'songtitle'} = $nowplaying->{'secondLine'};
					} else {
						if (exists $nowplaying->{'title'}) {$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($nowplaying->{'title'})};
					}
					
					$calculatedPlaying->{$station}->{'songyear'} = '';
					if (exists $nowplaying->{'release'}->{'year'}) {$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'release'}->{'year'}};
					$calculatedPlaying->{$station}->{'songlabel'} = '';
					if (exists $nowplaying->{'release'}->{'label'}) {$calculatedPlaying->{$station}->{'songlabel'} = $nowplaying->{'release'}->{'label'}};
					
					# main::DEBUGLOG && $log->is_debug && $log->debug('Preferences: DisableAlbumName='.$prefs->get('disablealbumname'));
					$calculatedPlaying->{$station}->{'songalbum'} = '';
					if (exists $nowplaying->{'release'}->{'title'}) {$calculatedPlaying->{$station}->{'songalbum'} = $nowplaying->{'release'}->{'title'}};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					if ( exists $nowplaying->{'visual'} ){
						$thisartwork = getcover($nowplaying->{'visual'}, $station, $info);
					}
					
					#if ($thisartwork ne ''){
						$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
					#}
					
					if ( exists $nowplaying->{'end'} && exists $nowplaying->{'start'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'end'} - $nowplaying->{'start'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0) {$calculatedPlaying->{$station}->{'songlth'} = $songDuration};
					}
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$calculatedPlaying->{$station}->{'songend'} = $expectedEndTime;
					
				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("$station - ($dataType) Did not find Current Song in retrieved data");

			}
			
			#$dumped =  Dumper $calculatedPlaying->{$station};
			#$dumped =~ s/\n {44}/\n/g;   
			#main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");

		} elsif ( ref($perl_data) ne "ARRAY" && ( exists $perl_data->{'now'} && exists $perl_data->{'media'} && exists $perl_data->{'slug'}) ) {
			
			# {
				# "now": {
					# "firstLine": "All things",
					# "secondLine": "Hieroglyphics",
					# "cover": {
						# "src": "https://www.radiofrance.fr/s3/cruiser-production/2021/10/09062710-ffa6-4526-979d-a681b252682c/400x400_rf_omm_0002143886_dnc.0123241567.jpg",
						# "webpSrc": "https://www.radiofrance.fr/s3/cruiser-production/2021/10/09062710-ffa6-4526-979d-a681b252682c/400x400_rf_omm_0002143886_dnc.0123241567.webp",
						# "legend": null,
						# "copyright": null,
						# "author": null,
						# "width": 400,
						# "height": 400,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGQAAAwEBAQAAAAAAAAAAAAAAAgMEBQAB/8QAIxAAAgICAgICAwEAAAAAAAAAAQIAEQMhEjEEURNBFCJxMv/EABcBAQEBAQAAAAAAAAAAAAAAAAIAAQP/xAAZEQADAQEBAAAAAAAAAAAAAAAAAQIRMSH/2gAMAwEAAhEDEQA/AJ/BxgpyIuUthx5AbWR+JneqvQEuxOMgIOmlLnjMe9JfwFJsNqNHi4lANWRDDi+IYEwr3uNSg6xbpj+MkqNCZZqzqa9cgRM9vGbkf7BaSYp9C8VVC2PuPK67icKsuIVQv3CVm+Snqvc4vp0BwoyEj7vUYzZTlB5AAfUMuo/yRFkKTfKSplh2NsuNmJYEH3OPlizoTwn9TRuRG7iW10zhoAJwUN2J4UULYFyTITy7lGE2hgawQOvUNAp71AbsQX0DNIecag2uQfySFdncFSeXcE9zpgD/2Q==",
						# "id": "09062710-ffa6-4526-979d-a681b252682c"
					# },
					# "song": {
						# "id": "0091febc-b622-4f87-bb53-6112e74b6890",
						# "title": "All things",
						# "year": 1998,
						# "release": {
							# "title": "3rd eye vision",
							# "label": "HIEROGLYPHICS IMPERIUM",
							# "reference": null
						# },
						# "interpreters": []
					# },
					# "nowTime": 1663944657,
					# "nowPercent": 90.72164948453609
				# },
				# "next": {
					# "firstLine": "Drop it like it's hot",
					# "secondLine": "Snoop Dogg & Pharrell Williams",
					# "cover": {
						# "src": "https://www.radiofrance.fr/s3/cruiser-production/2019/10/57994664-e633-41a7-a05f-beb048dec3ce/400x400_rf_omm_0001583467_dnc.0072299238.jpg",
						# "webpSrc": "https://www.radiofrance.fr/s3/cruiser-production/2019/10/57994664-e633-41a7-a05f-beb048dec3ce/400x400_rf_omm_0001583467_dnc.0072299238.webp",
						# "legend": null,
						# "copyright": null,
						# "author": null,
						# "width": 400,
						# "height": 400,
						# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGQAAAgMBAAAAAAAAAAAAAAAAAwQAAQUC/8QAKBAAAQQBAgUEAwEAAAAAAAAAAQACAxEEITEFEhMyUSJBUnEUgZHR/8QAFgEBAQEAAAAAAAAAAAAAAAAAAQAC/8QAGREBAQEBAQEAAAAAAAAAAAAAABEBMVES/9oADAMBAAIRAxEAPwAnFMowBrWdxSuNkzP3tw+kXi0YPI+9tEPDlijaeYkEewR9LMHfIxjgXV+11NIGAU0epZWQ5zpi4WWg6WjGUys7j/iRDGXM1jNWWdrSX5Q+KmVM54a0kmkqoxoZmSJ3co7R7pdoN6FQx1Hzf1DDqRkUjQErAAOnYOhBVZMUcLWuZ6r3r2Q8Vr53iMb+VeSx2PKWEgrQAbjSSO0Gh8pocJnrZqJjytmNEhpGw8rRGVQAIWL63PGe7GBi5A9uqzXxlshYNaTRJs6rpgFXQVwdE4a/pvqxtsr4k1hYHjvvVBi0mH2ry9ZdU4tJWb3RevL8iuqHgKUPCg//2Q==",
						# "id": "57994664-e633-41a7-a05f-beb048dec3ce"
					# },
					# "song": {
						# "id": "5c2fb4fd-67ff-40ac-a57e-f59e72dbbb78",
						# "title": "Drop it like it's hot",
						# "year": 2004,
						# "release": {
							# "title": "Rhythm & gangsta",
							# "label": null,
							# "reference": null
						# },
						# "interpreters": []
					# }
				# },
				# "delayToRefresh": 18000,
				# "slug": "fip_hiphop",
				# "media": {
					# "sources": [
						# {
							# "url": "https://stream.radiofrance.fr/fiphiphop/fiphiphop.m3u8?id=radiofrance",
							# "broadcastType": "live",
							# "format": "hls",
							# "bitrate": 0
						# },
						# {
							# "url": "http://icecast.radiofrance.fr/fiphiphop-hifi.aac?id=radiofrance",
							# "broadcastType": "live",
							# "format": "aac",
							# "bitrate": 192
						# },
						# {
							# "url": "https://icecast.radiofrance.fr/fiphiphop-midfi.mp3?id=radiofrance",
							# "broadcastType": "live",
							# "format": "mp3",
							# "bitrate": 128
						# }
					# ],
					# "startTime": 1663944481,
					# "endTime": 1663944675
				# },
				# "visual": {
					# "src": "https://www.radiofrance.fr/s3/cruiser-production/2022/07/af67eb80-feac-441e-aea6-ba7c653e220d/300x300_fip-hip-hop-2022-v12x-1.jpg",
					# "webpSrc": "https://www.radiofrance.fr/s3/cruiser-production/2022/07/af67eb80-feac-441e-aea6-ba7c653e220d/300x300_fip-hip-hop-2022-v12x-1.webp",
					# "legend": "FIP Hip-hop",
					# "copyright": "Aucun(e)",
					# "author": "",
					# "width": 300,
					# "height": 300,
					# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAGQABAQEBAQEAAAAAAAAAAAAAAwUEAQAC/8QAKBAAAQQBAwIFBQAAAAAAAAAAAQACAxEEBRIxEyEUMkFRYSI0QnGB/8QAFwEBAQEBAAAAAAAAAAAAAAAAAwEAAv/EABoRAQEBAAMBAAAAAAAAAAAAAAABAxExMhL/2gAMAwEAAhEDEQA/AK0d/wARZWW3GZuIJr2SRuG7b6qfmxyuyHDbcbhyjx8R1JzeCR6rHJIGBpFml12qMbI5mx1g0sAjMbwAwbr7LWcX6y/puLndzSWx1pn8N2POJ4t4BH7SosZmyECq+ClUGzs+5A+E0kbZG7XcIZBUEjx5gOVMOTI7uHuCLHxF6qqMSLeHUbCZS4chzcaS3uv8SUXiZX3TyAO6Vrbe1letS8OaR+SLe43yPRU1kGWdSFzPcUsjtOcT5wt0fC+kWPiLQPx92N0xV1VrMdPfdteBfKoLyVAYuP0GuBIJJ5TLq4sz/9k=",
					# "id": "af67eb80-feac-441e-aea6-ba7c653e220d"
				# }
			# }
			
			$dataType = 'rf6';
			my $nowplaying;
			my $thisItem;
			my $songItem;
			
			$thisItem = $perl_data;
			
			if ( exists($thisItem->{'now'}->{'song'} ) ){
				$songItem = $thisItem->{'now'}->{'song'};
				
				if (exists($songItem->{'title'}) && defined($songItem->{'title'}) && $songItem->{'title'} ne '' &&
				    exists($thisItem->{'now'}->{'firstLine'}) && $thisItem->{'now'}->{'firstLine'} eq $songItem->{'title'} && 
				    exists($thisItem->{'now'}->{'secondLine'}) && $thisItem->{'now'}->{'secondLine'} ne '' ){
					$info->{isSong} = true;
					$nowplaying = $perl_data;
				}
			}
			
			if ( $info->{isSong} ) {
			
				# $dumped =  Dumper $nowplaying;
				# $dumped =~ s/\n {44}/\n/g;   
				# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

				# main::DEBUGLOG && $log->is_debug && $log->debug("Time: ".time." Ends: ".$nowplaying->{'end_time'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current artist: ".$nowplaying->{'title'}." song: ".$nowplaying->{'subtitle'});
				# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$nowplaying->{'cover'});
				
				if (exists $nowplaying->{'media'}->{'startTime'}){ $calculatedPlaying->{$station}->{'songstart'} = $nowplaying->{'media'}->{'startTime'}};
				
				my $expectedEndTime = $hiResTime;
				
				if ( exists $nowplaying->{'media'}->{'endTime'} && $nowplaying->{'media'}->{'endTime'} > 0 ){ $expectedEndTime = $nowplaying->{'media'}->{'endTime'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly
					if (exists $thisItem->{'now'}->{'secondLine'} && defined($thisItem->{'now'}->{'secondLine'}) && $thisItem->{'now'}->{'secondLine'} ne '') {
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($thisItem->{'now'}->{'secondLine'});
					}

					if (exists $songItem->{'title'} && defined($songItem->{'title'}) && $songItem->{'title'} ne '') {
						$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($songItem->{'title'});
					}

					$calculatedPlaying->{$station}->{'songyear'} = '';
					if (exists $nowplaying->{'year'} && defined($nowplaying->{'year'}) ) {
						$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'year'};
					}

					# Note - Label and Album are not available in the "playing_item" but are in "song"
					# Take year if it is present and have seen times when not present above
					if ( exists $songItem->{'year'} && defined($songItem->{'year'}) ) {$calculatedPlaying->{$station}->{'songyear'} = $songItem->{'year'}};
					
					$calculatedPlaying->{$station}->{'songlabel'} = '';
					if ( exists $songItem->{'release'}->{'label'} && defined( $songItem->{'release'}->{'label'} ) && $songItem->{'release'}->{'label'} ne '' ) {$calculatedPlaying->{$station}->{'songlabel'} = _lowercase($songItem->{'release'}->{'label'})};
					
					$calculatedPlaying->{$station}->{'songalbum'} = '';
					if (exists $songItem->{'release'}->{'album'} && defined( $songItem->{'release'}->{'album'} ) && $songItem->{'release'}->{'album'} ne '' ) {$calculatedPlaying->{$station}->{'songalbum'} = _lowercase($songItem->{'release'}->{'album'})};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					if ( $thisartwork eq '' && exists $nowplaying->{'now'}->{'cover'} ){
						# Try to get it from the now playing
						$thisartwork = getcover($nowplaying->{'now'}->{'cover'}, $station, $info);
					}

					if ($thisartwork ne ''){
						$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
					}
					
					if ( exists $nowplaying->{'media'}->{'endTime'} && exists $nowplaying->{'media'}->{'startTime'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'media'}->{'endTime'} - $nowplaying->{'media'}->{'startTime'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0) {$calculatedPlaying->{$station}->{'songlth'} = $songDuration};
					}
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$calculatedPlaying->{$station}->{'songend'} = $expectedEndTime;
					
				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("$station ($dataType) - Did not find Current Song in retrieved data");

			}
			
			#$dumped =  Dumper $calculatedPlaying->{$station};
			#$dumped =~ s/\n {44}/\n/g;   
			#main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");
		} elsif ( ref($perl_data) ne "ARRAY" && ( exists $perl_data->{'now'} && exists $perl_data->{'now'}->{'concept'} && 
		          exists $perl_data->{'now'}->{'title'} && exists $perl_data->{'now'}->{'progress'}) ) {
			# https://www.francebleu.fr/api/live-locale/la-rochelle
			# {
			  # "now": {
			    # "id": "09ce3a69-5169-4a29-844b-d784751a4de4",
			    # "title": "Les infos de 06h00 du mardi 07 janvier 2025",
			    # "path": null,
			    # "startTime": "5h59",
			    # "endTime": "9h00",
			    # "progress": {
			      # "start": 1736225970,
			      # "end": 1736236800
			    # },
			    # "concept": {
			      # "title": "Le journal de 6h, ici La Rochelle",
			      # "path": "emissions/les-infos-de-06h00/la-rochelle"
			    # },
			    # "contact": null,
			    # "visual": {
			      # "mobile": {
				# "url": "https://www.francebleu.fr/s3/cruiser-production-eu3/2024/12/d943a241-9f1e-4a53-a651-8e2d3f93e101/400x400_sc_les-journaux-ici-la-rochelle-3000x3000.jpg",
				# "urlWebp": "https://www.francebleu.fr/s3/cruiser-production-eu3/2024/12/d943a241-9f1e-4a53-a651-8e2d3f93e101/400x400_sc_les-journaux-ici-la-rochelle-3000x3000.webp",
				# "legend": "Le journal, ici La Rochelle",
				# "width": 400,
				# "height": 400,
				# "preview": "/9j/2wBDACgcHiMeGSgjISMtKygwPGRBPDc3PHtYXUlkkYCZlo+AjIqgtObDoKrarYqMyP/L2u71////m8H////6/+b9//j/2wBDASstLTw1PHZBQXb4pYyl+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj4+Pj/wAARCAAqACoDASIAAhEBAxEB/8QAFwABAQEBAAAAAAAAAAAAAAAAAgEAA//EABgQAQEBAQEAAAAAAAAAAAAAAAABERIC/8QAGAEBAQEBAQAAAAAAAAAAAAAAAAIBAwT/xAAWEQEBAQAAAAAAAAAAAAAAAAAAEQH/2gAMAwEAAhEDEQA/AOEWBpSvRXM4UrnrazdHaei7cOm7RqnHVlBdKQ9bQ1NZSH0nQWpoqEzIga0bVoVTF1NRhr//2Q=="
			      # }
			    # }
			  # },
			  # "next": {
			    # "title": "ici matin, ici La Rochelle",
			    # "path": null,
			    # "time": "5h59 - 9h00"
			  # }
			# }			
			$dataType = 'rf7';
			my $nowplaying;
			my $thisItem;
			my $songItem;
			
			$thisItem = $perl_data;
			
			if (exists $perl_data->{'now'}->{'progress'}->{'start'} && defined $perl_data->{'now'}->{'progress'}->{'start'} && 
			    exists $perl_data->{'now'}->{'progress'}->{'end'} && defined $perl_data->{'now'}->{'progress'}->{'end'} &&
			    $hiResTime >= $perl_data->{'now'}->{'progress'}->{'start'} && $hiResTime <= $perl_data->{'now'}->{'progress'}->{'end'}+30) {
				# Station / Programme name provided so use that if it is on now
			
				if (exists $perl_data->{'now'}->{'concept'}->{'title'} && $perl_data->{'now'}->{'concept'}->{'title'} ne ''){
					$calculatedPlaying->{$station}->{'progtitle'} = $perl_data->{'now'}->{'concept'}->{'title'};
				}
				
				$calculatedPlaying->{$station}->{'progsubtitle'} = '';
				
				if (exists $perl_data->{'now'}->{'title'} && $perl_data->{'now'}->{'title'} ne '' && $perl_data->{'now'}->{'title'} ne $calculatedPlaying->{$station}->{'progtitle'}){
					$calculatedPlaying->{$station}->{'progsubtitle'} = $perl_data->{'now'}->{'title'};
				}
				$calculatedPlaying->{$station}->{proglogo} = '';
				
				if ($prefs->get('showprogimage')){
					my $progIcon = '';

					if (exists $perl_data->{'now'}->{'visual'}->{'mobile'}->{'url'}){
						# Station / Programme icon provided so use that
						$progIcon = $perl_data->{'now'}->{'visual'}->{'mobile'}->{'url'};
					}

					if ($progIcon ne '' && $progIcon !~ /$iconsIgnoreRegex->{$station}/ ){
						$calculatedPlaying->{$station}->{proglogo} = $progIcon;
					} else {
						# Icon not present or matches one to be ignored
						# if ($progIcon ne ''){main::DEBUGLOG && $log->is_debug && $log->debug("Prog Image skipped: $progIcon");}
						$calculatedPlaying->{$station}->{proglogo} = '';
					}
				}
				
				$calculatedPlaying->{$station}->{'progstart'} = $thisItem->{'now'}->{'progress'}->{'start'};
				$calculatedPlaying->{$station}->{'progend'} = $thisItem->{'now'}->{'progress'}->{'end'};
				
				# Work out programme duration and return if plausible
				$progDuration = $calculatedPlaying->{$station}->{'progend'} - $calculatedPlaying->{$station}->{'progstart'};
				
				# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Show Duration $progDuration");
				
				if ( $progDuration > 0 ) {$calculatedPlaying->{$station}->{'proglth'} = $progDuration};
			}
			
			#$dumped =  Dumper $calculatedPlaying->{$station};
			#$dumped =~ s/\n {44}/\n/g;   
			#main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");
		} else {
			# Do not know how to parse this - probably a mistake in setup of $meta or $station
			main::INFOLOG && $log->is_info && $log->info("Called for station $station - but do not know which format parser to use");
			$dumped =  Dumper $perl_data;
			$dumped =~ s/\n {44}/\n/g;
			$dumped = substr($dumped, 0, 1000);
			main::DEBUGLOG && $log->is_debug && $log->debug("Data starts: $dumped");
		}
	}
	
	# oh well...
	else {
		$content = '';
	}

	# Beyond this point should not use information from the data that was pulled because the code below is generic
	$dumped = Dumper $calculatedPlaying->{$station};
	# print $dumped;
	main::DEBUGLOG && $log->is_debug && $log->debug("$station - now $hiResTime data Type $dataType: Collected $dumped");

	# Hack to get around multiple stations playing the same show at the same time but info not being updated when switching to the 2nd
	# because it is the same base data
	$info->{stationid} = $station;
	
	#temporary hack
	# if ( $getschedulehack ) {
		# $thismeta = &getprogrammemeta( $client, $url, false, $progListPerStation );
	# }
	
	# Zap fields that have been seen with different encodings because it makes subsequent comparison difficult
	for my $fieldName ( 'progtitle','progsubtitle','progsynopsis','songtitle','songartist','songalbum','songlabel' ) {
		$calculatedPlaying->{$station}->{$fieldName} =~ s/\x{a0}/ /g;	# non-breaking space to space
		$calculatedPlaying->{$station}->{$fieldName} =~ s/\x{2019}/'/g;	# special apostoprophe to single quote
	}
	
	# Note - the calculatedPlaying info contains historic data from previous runs
	# Calculate from what is thought to be playing (programme or song) and put it into $info (which reflects what we want to show)
	if ($calculatedPlaying->{$station}->{'songtitle'} ne '' && $calculatedPlaying->{$station}->{'songartist'} ne '' &&
	    $calculatedPlaying->{$station}->{'songstart'} <= $hiResTime && $calculatedPlaying->{$station}->{'songend'} >= $hiResTime - cacheTTL ) {
		# We appear to know about a song
		$info->{title} = $calculatedPlaying->{$station}->{'songtitle'};
		$info->{remote_title} = $info->{title};
		# $info->{remotetitle} = $info->{title};
		
		$info->{artist} = $calculatedPlaying->{$station}->{'songartist'};
		
		if (!$prefs->get('disablealbumname')){
			$info->{album} = $calculatedPlaying->{$station}->{'songalbum'};
		} else {$info->{album} = '';}
		
		$info->{label} = $calculatedPlaying->{$station}->{'songlabel'};
		$info->{year} = $calculatedPlaying->{$station}->{'songyear'};
		$info->{cover} = $calculatedPlaying->{$station}->{'songcover'};
		
		if ($info->{cover} eq '') {$info->{cover} = $icons->{$station}}
		
		$info->{startTime} = $calculatedPlaying->{$station}->{'songstart'};
		$info->{endTime} = $calculatedPlaying->{$station}->{'songend'};
		
		if ($calculatedPlaying->{$station}->{'songlth'} > 0 && $calculatedPlaying->{$station}->{'songlth'} <= maxSongLth && !$hideDuration) {
			# Provide duration if explcitly given because the songend time might have been guestimated
			$info->{duration} = $calculatedPlaying->{$station}->{'songlth'};
		}
		
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - song found");
		
	} elsif ($calculatedPlaying->{$station}->{'progtitle'} ne '' &&
	         $calculatedPlaying->{$station}->{'progstart'} < $hiResTime && $calculatedPlaying->{$station}->{'progend'} >= $hiResTime + cacheTTL ) {
		# We appear to know about a programme
		
		my $thisTitle;
		my $thisSubtitle;
		
		$thisTitle = $calculatedPlaying->{$station}->{'progtitle'};
		$thisSubtitle = $calculatedPlaying->{$station}->{'progsubtitle'};
		
		$info->{album} = '';
		if ( $thisSubtitle ne '' ){
			# Subtitle (segment) given so add to title or put in album (synopsis) if no synopsis given
			if ($calculatedPlaying->{$station}->{'progsynopsis'} ne '' || $prefs->get('excludesynopsis')){
				# There is a synopsis or we should not use the album field then append subtitle to title (if title not at the start of the subtitle)
				if ($thisSubtitle !~ /^\Q$thisTitle\E/i ){
					$thisTitle = $thisTitle." / ".$thisSubtitle;
				} else {
					$thisTitle = $thisSubtitle;
				}
			} else {
				$info->{album} = $thisSubtitle;
			}
		}

		$info->{title} = $thisTitle;
		$info->{remote_title} = $info->{title};
		# $info->{remotetitle} = $info->{title};
		
		$info->{artist} = '';
		
		if ( !$prefs->get('excludesynopsis') && $calculatedPlaying->{$station}->{'progsynopsis'} ne '' ){
			$info->{album} = $calculatedPlaying->{$station}->{'progsynopsis'};
		}
		
		undef $info->{label};
		undef $info->{year};
		
		if ($prefs->get('showprogimage')){
			$info->{cover} = $calculatedPlaying->{$station}->{'proglogo'};
		} else {
			$info->{cover} = '';
		}
		if ($info->{cover} eq '') {$info->{cover} = $icons->{$station}}
		
		$info->{startTime} = $calculatedPlaying->{$station}->{'progstart'};
		$info->{endTime} = $calculatedPlaying->{$station}->{'progend'};
		
		if ($calculatedPlaying->{$station}->{'proglth'} > 0 && $calculatedPlaying->{$station}->{'proglth'} <= maxShowLth && !$hideDuration) {
			# Provide duration if explcitly given because the progend time might have been guestimated
			$info->{duration} = $calculatedPlaying->{$station}->{'proglth'};
		}
		
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - programme found");
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Not found something for $hiResTime");
		# Did not find a programme so maybe we need a fresh set of programme data
		$thismeta = &getprogrammemeta( $client, $url, false, $progListPerStation );
	}

	$dumped = Dumper $info;
	# print $dumped;
	main::DEBUGLOG && $log->is_debug && $log->debug("$station - Info collected $dumped");
	
	my $dataChanged = false;
	
	if ($meta->{$station}->{busy} > 0){
		$info->{busy} = $meta->{$station}->{busy}-1;
	} else {$info->{busy} = 0;}
	
	if ($info->{busy} < 0 || $info->{busy} > 2){
		# Busy counter gone too low or too high - something odd happening - so log it
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Busy counter has unexpected value ".$info->{busy});
		$info->{busy} = 0;	
	}

	# Get information about what this device is playing
	my $controller = $client->controller()->songStreamController();
	my $song = $controller->song() if $controller;
	
	if (defined $info->{title} && defined $info->{artist} && defined $meta->{$station}->{title} && defined $meta->{$station}->{artist}){
		# Have found something this time - if same as playing then check for additional info available
		if (($info->{title} eq $meta->{$station}->{title} && $info->{artist} eq $meta->{$station}->{artist}) ||
			$info->{endTime} eq $meta->{$station}->{endTime}) {
			# Seems to be the same song - so check for new (or now missing) data
			# Have seen occasions when same song has slightly different artist names - so also say match if endTime is the same
			if ($meta->{$station}->{cover} eq $icons->{$station} && $info->{cover} ne $meta->{$station}->{cover}){
				# looks like we have artwork and before was the default
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Enriching with extra artwork: ".$info->{cover});
				$dataChanged = true;
			} elsif ($info->{cover} eq $icons->{$station} && $meta->{$station}->{cover} ne $icons->{$station}){
				# Had artwork before but do not now - so preserve old
				$info->{cover} = $meta->{$station}->{cover};
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected artwork: ".$info->{cover});
			}
			
			# Have seen occasions when one source has a "label" and the other does not so preserve it
			if ( defined $info->{label} && !defined $meta->{$station}->{label} ){
				# looks like we have label and did not before
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Enriching with label name: ".$info->{label});
				$dataChanged = true;
			} elsif (!defined $info->{label} && defined $meta->{$station}->{label}){
				# Had label before but do not now - so preserve old
				$info->{label} = $meta->{$station}->{label};
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected label name: ".$info->{label});
			}

			if ( $info->{artist} eq '' ){
				# No artist - so a programme
				if ( $info->{title} eq $meta->{$station}->{album} ){
					# The new artist (prog title) is the same as the old album (prog subtitle)
					# so treat as a special case where one of the data sources is providing incomplete or incorrect data
					$info->{title} = $meta->{$station}->{title};
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected title: ".$info->{title});
				}
				
				if ( $info->{title} ne $meta->{$station}->{title} && index($meta->{$station}->{title}, $info->{title} ) == 0 ){
					# If the new title is at the start of the old title then keep the old (longer) title
					$info->{title} = $meta->{$station}->{title};
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected title: ".$info->{title});
				}
				
				if ( $info->{album} eq '' && $meta->{$station}->{album} ne '' ){
					# No album (prog subtitle) but had one before
					# so treat as a special case where one of the data sources is providing incomplete or incorrect data
					$info->{album} = $meta->{$station}->{album};
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected album: ".$info->{album});
				}
			}

			if ( (defined $info->{album} && !defined $meta->{$station}->{album}) ||
			     (!defined $info->{album} && defined $meta->{$station}->{album}) ){
				# Album presence has changed
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Album presence changed");
				$dataChanged = true;
			} elsif (defined $info->{album} && $info->{album} ne '' && defined $meta->{$station}->{album} &&
				$info->{album} ne $meta->{$station}->{album} ){
				# Album value changed
				$dataChanged = true;
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Album contents changed");
			}

			# Just in case ...
			if ( defined $info->{year} && !defined $meta->{$station}->{year} ){
				# looks like we have year and did not before
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Enriching with year: ".$info->{year});
				$dataChanged = true;
			} elsif (!defined $info->{year} && defined $meta->{$station}->{year}){
				# Had year before but do not now - so preserve old
				$info->{year} = $meta->{$station}->{year};
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected year: ".$info->{year});
			}
			
			if ( defined $meta->{$station}->{stationid} && $meta->{$station}->{stationid} ne $info->{stationid} ){
				# Details appear to be the same but it is a different station ... simulcast
				# so say data has changed to try to force an update
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Station changed from $meta->{$station}->{stationid}");
				$dataChanged = true;
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - appears to be the same as before");
		}
	}
	
	if (!defined $info->{title} || !defined $info->{artist}){
		# Looks like nothing much was found - but might have had info from a different metadata fetch that is still valid
		# if (!defined $info->{title}){main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - title not defined");}
		# if (!defined $info->{artist}){main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - artist not defined");}
		
		if ((!defined $meta->{$station}->{artist} || $meta->{$station}->{artist} eq '') && 
			defined $meta->{$station}->{title} && $meta->{$station}->{title} ne '' ){
			# Not much track details found BUT previously had a programme name (no artist) so keep old programme name - with danger that it is out of date
			if (!defined $info->{title} &&
			    defined $meta->{$station}->{endTime} && $meta->{$station}->{endTime} >= $hiResTime - cacheTTL){
				$info->{title} = $meta->{$station}->{title};
				$info->{endTime} = $meta->{$station}->{endTime};	# Copy back the expected end-time since it will be saved back to $meta at end otherwise will advance by being set in $info at the entry point
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected programme name: ".$info->{title}." - scheduled end:".$meta->{$station}->{endTime});
			}
		# } elsif (defined $meta->{$station}->{endTime} && $meta->{$station}->{endTime} >= $hiResTime + cacheTTL){
		} elsif (defined $meta->{$station}->{endTime} && $meta->{$station}->{endTime} >= $hiResTime - cacheTTL){
			# If the stored data is still within time range then keep it (allowing for timing being slightly out)
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected artist and title - scheduled end:".$meta->{$station}->{endTime}." Compared to:".$hiResTime);
			if (defined $meta->{$station}->{artist}){$info->{artist} = $meta->{$station}->{artist};}
			if (defined $meta->{$station}->{title}){$info->{title} = $meta->{$station}->{title};}
			if (defined $meta->{$station}->{cover}) {
				if ($info->{cover} eq $icons->{$station}){
					# If is the station icon then overwrite it with old value (which might be the same)
					$info->{cover} = $meta->{$station}->{cover};
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Replace default station icon with $info->{cover}");
				}
			}
			if (defined $meta->{$station}->{icon}) {$info->{icon} = $meta->{$station}->{icon}};
			if (defined $meta->{$station}->{album}) {$info->{album} = $meta->{$station}->{album}};
			if (defined $meta->{$station}->{year}) {$info->{year} = $meta->{$station}->{year}};
			if (defined $meta->{$station}->{label}) {$info->{label} = $meta->{$station}->{label}};
			$info->{endTime} = $meta->{$station}->{endTime};	# Copy back the expected end-time since it will be saved back to $meta at end otherwise will advance by being set in $info at the entry point
		}
	}
		
	if ( (defined $info->{title} && (!defined $meta->{$station}->{title} || ($info->{title} ne $meta->{$station}->{title} && $info->{endTime} ne $meta->{$station}->{endTime})))
		|| (defined $info->{artist} && (!defined $meta->{$station}->{artist} || ($info->{artist} ne $meta->{$station}->{artist} && $info->{endTime} ne $meta->{$station}->{endTime}))) 
		|| (!defined $info->{title} && defined $meta->{$station}->{title})
		|| $dataChanged
		) {
	
		# Core data has changed since last time (including now no data but was before)
		my $thisartist = '';
		my $thistitle = '';
		if (defined $info->{artist}) {$thisartist = $info->{artist}};
		if (defined $info->{title}) {$thistitle = $info->{title}};
		
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Got now playing information - artist: $thisartist title: $thistitle");
		
		# main::DEBUGLOG && $log->is_debug && $log->debug("Checking what is in master data");
		# $dumped =  Dumper $client->master->pluginData;
		# main::DEBUGLOG && $log->is_debug && $log->debug($dumped);

		&updateClient( $client, $song, $info, $hiResTime );
	}
	
	if ( $client->isPlaying ){
		# Request call back after timer expires - from debugging it looks like there can be a lot of these so try to limit the number
		&deviceTimer( $client, $info, $url );
	}
	
	return $info;
}


sub updateClient {
	# Send Now Playing info to the client/device
	my ( $client, $song, $info, $hiResTime ) = @_;
	
	my $dumped;
	my $thisartist = '';
	my $thistitle = '';
	my $thiscover = '';
	my $thisicon = '';
	my $thisalbum = '';
	my $thisstationid = '';
		
	if (defined $info->{artist}) {$thisartist = $info->{artist}};
	if (defined $info->{title}) {$thistitle = $info->{title}};
	if (defined $info->{cover}) {$thiscover = $info->{cover}};
	if (defined $info->{icon}) {$thisicon = $info->{icon}};
	if (defined $info->{stationid}) {$thisicon = $info->{stationid}};

	if ($prefs->get('appendlabel') && defined $info->{album} && defined $info->{label} && $info->{label} ne ''){
		# Been asked to add the record label name to album name if present
		my $appendStr = ' / '.$info->{label};
		# Only add it if not already there (could happen when more than one data source)
		# Note - might not be the last field on the line because of Year below so do not test for EOL $)
		if ($info->{album} !~ m/\Q$appendStr\E/){
			$info->{album} .= $appendStr;
		}
	}

	if ($prefs->get('appendyear') && defined $info->{album} && defined $info->{year} && $info->{year} ne ''){
		# Been asked to add the year to album name if present
		my $appendStr = ' / '.$info->{year};
		# Only add it if not already there (could happen when more than one data source)
		if ($info->{album} !~ m/\Q$appendStr\E$/){
			$info->{album} .= $appendStr;
		}
	}
	# Set $thisalbum here because it might have been modified above
	if (defined $info->{album}) {$thisalbum = $info->{album}};
	
	my $deviceName = "";
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("no device name");
	} else {
		$deviceName = $client->name;
	};

	my $lastartist = '';
	my $lasttitle = '';
	my $lastcover = '';
	my $lastalbum = '';
	my $laststationid = '';
	if (defined $myClientInfo->{$deviceName}->{lastartist}) {$lastartist = $myClientInfo->{$deviceName}->{lastartist}};
	if (defined $myClientInfo->{$deviceName}->{lasttitle}) {$lasttitle = $myClientInfo->{$deviceName}->{lasttitle}};
	if (defined $myClientInfo->{$deviceName}->{lastcover}) {$lastcover = $myClientInfo->{$deviceName}->{lastcover}};
	if (defined $myClientInfo->{$deviceName}->{lastalbum}) {$lastalbum = $myClientInfo->{$deviceName}->{lastalbum}};
	if (defined $myClientInfo->{$deviceName}->{stationid}) {$laststationid = $myClientInfo->{$deviceName}->{stationid}};
	
	if ($song && ($lastartist ne $thisartist || $lasttitle ne $thistitle ||
		      $lastcover ne $thiscover || $lastalbum ne $thisalbum ||
		      $laststationid ne $thisstationid ) ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Client: $deviceName - pushing Now Playing $thisartist - $thistitle");
			# main::DEBUGLOG && $log->is_debug && $log->debug("Client: $deviceName - pushing cover: $thiscover icon: $thisicon");
			if (defined $info->{startTime}){main::DEBUGLOG && $log->is_debug && $log->debug("Client: $deviceName - Now: $hiResTime Scheduled start: $info->{startTime}")};
			
			# $song->pluginData( wmaMeta => $info );
			
			if (!$prefs->get('hidetrackduration')){
				my $startOffset;
				
				$startOffset = 0;
				# Pushing duration and startOffset makes the duration and playing position display
				if (defined $info->{duration}){
					$song->duration( $info->{duration} );
					# if (defined $info->{startTime}){
						# # We know when it was scheduled and what time it is now ... so use the difference to modify the duration
						# $song->duration( $info->{duration}+$info->{startTime}-$hiResTime );
						# # Copy back the modified duration
						# $info->duration( $song->{duration} );
					# };
					$startOffset = $info->{startTime}-$hiResTime if defined $info->{startTime};
				} else {
					$song->duration( 0 );
				};

				# However, might need some adjusting to allow for joining song in the middle and stream delays
				# if (defined $info->{endTime} && defined $info->{duration}){
				# 	# There is an end time and an expected duration ... but might have joined after track start so adjust if needed
				# 	if ($info->{endTime}-$hiResTime < $info->{duration}){
				# 		$song->duration( $info->{endTime}-$hiResTime );
				# 		main::DEBUGLOG && $log->is_debug && $log->debug("Client: $deviceName - adjusting duration from $info->{duration} to $song->duration");
				# 	}
				# }

				#$song->startOffset( -$client->songElapsedSeconds );
				$song->startOffset( -$startOffset-$client->songElapsedSeconds );
			} else {
				# Do not show duration so remove it in case old data there from song before this was disabled
				$song->duration( 0 );
				# Copy back the modified duration
				$info->duration( $song->{duration} );
			}
			
			$dumped =  Dumper $info;
			$dumped =~ s/\n {44}/\n/g;   
			main::INFOLOG && $log->is_info && $log->info("About to push:$dumped");


			$song->pluginData( wmaMeta => $info );
			# $client->master->pluginData( metadata => $info );

			$client->currentPlaylistUpdateTime($hiResTime);	# pretend the playlist has changed so that elseehere (Default skin in particular) does a full update - this helps where the "album" has changed but not the title
			
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			$myClientInfo->{$deviceName}->{lastpush} = $hiResTime;
			$myClientInfo->{$deviceName}->{lastartist} = $thisartist;
			$myClientInfo->{$deviceName}->{lasttitle} = $thistitle;
			$myClientInfo->{$deviceName}->{lastcover} = $thiscover;
			$myClientInfo->{$deviceName}->{lastalbum} = $thisalbum;
	}
}


sub deviceTimer {

	my ( $client, $info, $url ) = @_;
	
	my $dumped;
	
	my $hiResTime = getLocalAdjustedTime+$prefs->get('streamdelay');	# Use real time (not adjusted) because will be setting real timer
	
	my $station = &matchStation( $url );
	my $originalStation = $station;
	
	my $deviceName = "";

	my $song = $client->playingSong();
	
	# Warning .... "song" is huge so do not leave this enabled unless doing very specific debugging
	#$dumped =  Dumper $song;
	#$dumped =~ s/\n {44}/\n/g;   
	#main::DEBUGLOG && $log->is_debug && $log->debug("$station - deviceTime - Song:$dumped");
	
	my $playingURL = "";
	if ( $song && $song->streamUrl ) { $playingURL = $song->streamUrl}

	if ($playingURL ne $url){
		# Given stream URL not the same now as we had before implies listener has changed station
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - deviceTimer - client ".$client->name." stream changed to $playingURL from $url");
		# However, it might be an alternative that leads to the same station (redirects) or another in the family so check
		$station = &matchStation( $playingURL );
		$url = $playingURL;
		if ($originalStation ne $station) {
			main::DEBUGLOG && $log->is_debug && $log->debug("deviceTimer - Now set to - $station - was $originalStation - URL $playingURL");
		}
	} else {
		# If streamUrl not found then something is odd - so report it to help determine issue
		if (!$song || !$song->streamUrl || !$song->streamUrl ne ""){
			# Odd?
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - deviceTimer - Client: $deviceName - streamUrl issue $playingURL");
		}
	}
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - no device name");
	} else {
		$deviceName = $client->name;
	};
	
	# Request call back at end of song or in TTL if time now known

	# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - About to set timer");
	
	my $nextPollInt = cacheTTL;
	my $nextPoll = $hiResTime + $nextPollInt;
	
	if (exists $info->{endTime}){
		if ( $info->{endTime} > $nextPoll && $info->{endTime} - $nextPoll < 300) {
			# Looks like current track finishes in less than 300 seconds so poll just after that
			$nextPoll = $info->{endTime} + 1 + $prefs->get('streamdelay');
			
			$nextPollInt = $nextPoll - $hiResTime + $prefs->get('streamdelay');
		}
	} else {
		# Really should exist so output some debugging
		main::DEBUGLOG && $log->is_debug && $log->debug("$station endTime does not exist - this is unexpected");
	}

	my $deviceNextPoll = 0;
	
	if ($myClientInfo->{$deviceName}->{nextpoll}) {$deviceNextPoll = $myClientInfo->{$deviceName}->{nextpoll}};
	
	if ($deviceNextPoll >= $nextPoll){
		# If there is already a poll outstanding then skip setting up a new one
		$nextPollInt = $deviceNextPoll-$hiResTime+$prefs->get('streamdelay');
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Skipping setting poll $nextPoll - already one ".$myClientInfo->{$deviceName}->{nextpoll}." Due in: $nextPollInt");
	} elsif ( $station ne '' && $client->isPlaying ) {
		# If there is still a station and still playing then set up new timer
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Setting next poll to fire at $nextPoll Interval: $nextPollInt");

		Slim::Utils::Timers::killTimers($client, \&timerReturn);

		$myClientInfo->{$deviceName}->{nextpoll} = $nextPoll;
		Slim::Utils::Timers::setTimer($client, $nextPoll, \&timerReturn, $url);
	}
}

sub getDayMenu {
	my ( $client, $callback, $args, $passDict ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++getDayMenu");

	my $now       = time();
	my $stationid = $passDict->{'stationid'};

	my $menu      = [];

	my $daysofweek = string('PLUGIN_RADIOFRANCE_DAYSOFWEEKSHORT');
	$daysofweek = string('PLUGIN_RADIOFRANCE_DAYSOFWEEK') if $prefs->get('scheduledayname') == 2;
	my @daysofweek_arr = split(/,/, $daysofweek);

	my $numberOfDays = $prefs->get('schedulenumofdays');

	for ( my $i = 0 ; $i < $numberOfDays ; $i++ ) {
		my $d = '';
		my $epoch = $now - ( 86400 * $i );
		# $d = strftime( '%a %d/%m', localtime($epoch) );
		# Do not rely of strftime to get the day in text because it does not know
		# which language the user is set to in LMS and they might not have set it at the OS level
		# PLUGIN_RADIOFRANCE_DAYSOFWEEKSHORT
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime($epoch);
		
		if ( $prefs->get('scheduledayname') != 0 ) { $d = $daysofweek_arr[$wday].' '};
		$d .= sprintf("%02d",$mday).'/'.sprintf("%02d",$mon+1);

		my $scheduledate = strftime( '%Y-%m-%d', localtime($epoch) );

		push @$menu,
		  {
			name        => $d,
			type        => 'link',
			url         => \&getSchedulePage,
			passthrough => [
				{
					scheduledate => $scheduledate,
					stationid => $stationid
				}
			],
		  };
	}
	$callback->( { items => $menu } );
	main::DEBUGLOG && $log->is_debug && $log->debug("--getDayMenu");
	return;
}


sub getSchedulePage {
	my ( $client, $callback, $args, $passDict ) = @_;

	main::DEBUGLOG && $log->is_debug && $log->debug("++getSchedulePage");	

	$dumped = Dumper $passDict;
	# main::DEBUGLOG && $log->is_debug && $log->debug("passDict: $dumped");
	
	my $station = $passDict->{'stationid'};
	my $scheduledate = $passDict->{'scheduledate'};	# yyyy-mm-dd
	
	my $menu = [];
	my $hiResTime = getLocalAdjustedTime;
	
	my $schedulecachetimer = $prefs->get('schedulecachetimer');
	
	$log->info('Getting day menu');

	my $sourceUrl = '';
	
	if ( exists $stationSet->{$station}->{'ondemandurl'} && $stationSet->{$station}->{'ondemandurl'} ne ''){
		$sourceUrl = $stationSet->{$station}->{'ondemandurl'};
	} else {
		$sourceUrl = $urls->{$pluginName.'ondemandurl'};
	}

	if ( $sourceUrl =~ /\$\{.*\}/ ){
		# Special string to be replaced
		$sourceUrl =~ s/\$\{stationid\}/$stationSet->{$station}->{'stationid'}/g;
		$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
		$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
		$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
		$sourceUrl =~ s/\$\{datestring\}/$scheduledate/g;
	}
	
	my %headers = ();
	 
	if ( exists $stationSet->{$station}->{'ondemandheaders'} && $stationSet->{$station}->{'ondemandheaders'} ne ''){
		%headers = %{ $stationSet->{$station}->{'ondemandheaders'} };
	} else {
		%headers = %{ $urls->{$pluginName.'ondemandheaders'}; };
	}
	
	if ( my $cachemenu = _getCachedMenu($sourceUrl) ) {

		$callback->( { items => $cachemenu } );
		main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedulePage cached menu");	
		return;
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching programme data from $sourceUrl");

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;

			$log->debug('Schedule retreived');
			_parseSchedule( $http->content,  $menu);
			_cacheMenu($sourceUrl, $menu, $schedulecachetimer*60);

			$callback->( { items => $menu } );
		},

		# Called when no response was received or an error occurred.
		sub {
			$log->warn("error: $_[1]");
			$callback->( [ { name => $_[1], type => 'text' } ] );
		}
	)->get($sourceUrl, %headers);

	main::DEBUGLOG && $log->is_debug && $log->debug("--getSchedulePage");	
	return;

}

# Radio France - edited example of schedule file
# {
	# "links": {
		# "self": "/v1/stations/1/steps?fields%5Bdiffusions%5D=title%2CstartTime%2CendTime%2CmainImage%2Cvisuals%2CstationId&fields%5Bshows%5D=title%2Cvisuals%2CstationId%2CmainImage&filter%5Bdepth%5D=1&filter%5Bend-time%5D=2021-02-20T21%3A59&filter%5Bstart-time%5D=2021-02-19T22%3A00&include%5B0%5D=children-steps&include%5B1%5D=children-steps.diffusion&include%5B2%5D=children-steps.diffusion.manifestations&include%5B3%5D=children-steps.show&include%5B4%5D=diffusion&include%5B5%5D=diffusion.manifestations&include%5B6%5D=diffusion.station&include%5B7%5D=show"
	# },
	# "data": [
		# {
			# "id": "b6123089-f5c6-478b-a778-5ae0ad0f94aa",
			# "type": "steps",
			# "attributes": {
				# "title": "Le journal de 23h",
				# "startTime": 1613772000,
				# "endTime": 1613772600,
				# "depth": 1,
				# "embedType": "expression",
				# "multiDiffusion": false,
				# "radioMetadata": {
					# "id": "64159e5b-64ab-4dbd-88c4-729ea55a5ae3_1"
				# }
			# },
			# "relationships": {
				# "diffusion": {
					# "data": {
						# "type": "diffusions",
						# "id": "769f81d8-23a8-4678-bbb8-866fc002f8eb"
					# }
				# },
				# "show": {
					# "data": {
						# "type": "shows",
						# "id": "2510ac6e-d25a-11e0-b8ee-842b2b72cd1d"
					# }
				# },
				# "station": {
					# "data": {
						# "type": "stations",
						# "id": "1"
					# }
				# }
			# }
		# },

# ...

	# ],
	# "included": [
# ...
		# {
			# "id": "769f81d8-23a8-4678-bbb8-866fc002f8eb",
			# "type": "diffusions",
			# "attributes": {
				# "title": "Le journal de 23h du vendredi 19 février 2021",
				# "startTime": 1613772000,
				# "endTime": 1613772600,
				# "visuals": [
					# {
						# "name": "banner",
						# "visual_uuid": "4256a1da-f202-4cfa-8c0b-db0fb846da66"
					# },
					# {
						# "name": "concept_visual",
						# "visual_uuid": "aeb5db31-ea32-4149-8106-bc66c3ab26b7"
					# }
				# ]
			# },
			# "relationships": {
				# "bouquets": {
					# "data": [
						# {
							# "type": "shows",
							# "id": "6618e8fd-8297-4eac-800c-c6707ff5c879"
						# }
					# ]
				# },
				# "manifestations": {
					# "data": [
						# {
							# "type": "manifestations",
							# "id": "2c181ccd-cebd-4f49-88cc-32753c4c7e7e"
						# },
						# {
							# "type": "manifestations",
							# "id": "99c96fe1-4aa1-4a6f-8dac-1b387308c3ea"
						# },
						# {
							# "type": "manifestations",
							# "id": "527b604d-88e6-46f8-a075-2fa95418bcb9"
						# },
						# {
							# "type": "manifestations",
							# "id": "f84ccc0f-f076-4f67-88ae-75ac98a0c087"
						# }
					# ]
				# },
				# "show": {
					# "data": {
						# "type": "shows",
						# "id": "2510ac6e-d25a-11e0-b8ee-842b2b72cd1d"
					# }
				# },
				# "station": {
					# "data": {
						# "type": "stations",
						# "id": "1"
					# }
				# },
				# "steps": {
					# "data": [
						# {
							# "type": "steps",
							# "id": "b6123089-f5c6-478b-a778-5ae0ad0f94aa"
						# }
					# ]
				# },
				# "themes": {
					# "data": [
						# {
							# "type": "taxonomies",
							# "id": "b14ae358-460b-493a-a7c6-e9ffc23d3d11"
						# }
					# ]
				# }
			# }
		# },
# ...
		# {
			# "id": "2c181ccd-cebd-4f49-88cc-32753c4c7e7e",
			# "type": "manifestations",
			# "attributes": {
				# "title": "Le journal de 23h",
				# "type": "complet",
				# "mediaType": "mp3",
				# "url": "https://rf.proxycast.org/2c181ccd-cebd-4f49-88cc-32753c4c7e7e/21003-19.02.2021-ITEMA_22579387-2021F10770S0050.mp3",
				# "duration": 651,
				# "principal": false,
				# "isDeleted": false,
				# "date": 1613772600,
				# "isStreamable": false,
				# "isDownloadable": true,
				# "downloadExpirationDate": 1645225200,
				# "isStreamableOutsideFrance": false,
				# "isDownloadableOutsideFrance": true,
				# "podcastId": 21003,
				# "radioMetadata": {
					# "magnetothequeId": "2021F10770S0050"
				# }
			# },
			# "relationships": {
				# "diffusions": {
					# "data": [
						# {
							# "type": "diffusions",
							# "id": "769f81d8-23a8-4678-bbb8-866fc002f8eb"
						# }
					# ]
				# },
				# "station": {
					# "data": {
						# "type": "stations",
						# "id": "1"
					# }
				# }
			# }
		# },
# ...
	# ]
# }


sub _parseSchedule {
	my $content     = shift;
	my $menu        = shift;

	main::DEBUGLOG && $log->is_debug && $log->debug("++_parseSchedule");	

	my $station = '';
	
	my @data = ();
	my @included = ();
	my @menuPrepare = ();
	# Hashes for easier lookups
	my %data_hash = ();
	my %included_hash = ();


	my $__getItemDetails = sub  {
		my $entry = shift;
		
		my %progInfo = ();
		# Arrays of references to data elsewhere in the structure
		my @proglinksbroadcast = ();
		my @proglinkssegments = ();
		my @streamUrls = ();
		my $progstreamset = [];
		my $progstreamurl = '';
		my $progid = '';
		my $diffusionid = '';
		
		my $id_manifestation = '';

		$dumped = Dumper $entry;
		main::DEBUGLOG && $log->is_debug && $log->debug("__getItemDetails checking: $dumped");
		
		my $attributes = $entry->{attributes};
		
		$progInfo{'title'} = '';
		$progInfo{'episodetitle'} = '';
		$progInfo{'start'} = 0;		# unixtime

		if ( exists $attributes->{title} ) {
			if ( exists $entry->{type} && $entry->{type} eq 'shows' ) {
				$progInfo{'title'} = $attributes->{title};
			} else {
				$progInfo{'episodetitle'} = $attributes->{title};
			}
		}
		
		if ( exists $entry->{relationships}->{show}->{data}->{type} && $entry->{relationships}->{show}->{data}->{type} eq 'shows' &&
		     exists $entry->{relationships}->{show}->{data}->{id} && $entry->{relationships}->{show}->{data}->{id} ne '' ){
			$progid = $entry->{relationships}->{show}->{data}->{id};
			
			if ( exists $included_hash{ $progid }->{attributes}->{title} ) {
				$progInfo{'title'} = $included_hash{ $progid }->{attributes}->{title};
			}
		}
		#main::DEBUGLOG && $log->is_debug && $log->debug("-prog1: $progInfo{'title'} / $progInfo{'episodetitle'}");

		# Replace non-breaking space with space (seen in France Inter "Grand bien vous fasse\x{a0}!"
		$progInfo{'title'} =~ s/\x{a0}/ /g;
		$progInfo{'title'} =~ s/\x{2019}/'/g;
		$progInfo{'episodetitle'} =~ s/\x{a0}/ /g;
		$progInfo{'episodetitle'} =~ s/\x{2019}/'/g;
		
		if ( exists $attributes->{startTime} ) {$progInfo{'start'} = $attributes->{startTime};}

		if ( exists $entry->{relationships}->{show}->{data}->{type} &&
		    $entry->{relationships}->{show}->{data}->{type} eq 'shows' &&
		    exists $entry->{relationships}->{show}->{data}->{id} ) {
			$progInfo{'proglinkshow'} = $entry->{relationships}->{show}->{data}->{id};
			#main::DEBUGLOG && $log->is_debug && $log->debug("pushed show $entry->{relationships}->{show}->{data}->{id}");
		}
		
		if ( exists $entry->{relationships}->{diffusion}->{data}->{type} &&
		    $entry->{relationships}->{diffusion}->{data}->{type} eq 'diffusions' &&
		    exists $entry->{relationships}->{diffusion}->{data}->{id} ) {
			$diffusionid = $entry->{relationships}->{diffusion}->{data}->{id};
			push @proglinksbroadcast, $diffusionid;
			#main::DEBUGLOG && $log->is_debug && $log->debug("pushed diffusion $entry->{relationships}->{diffusion}->{data}->{id}");
			if ( exists $included_hash{$diffusionid}->{relationships}->{manifestations}->{data} ){
				$progstreamset = $included_hash{$diffusionid}->{relationships}->{manifestations}->{data};
			}

		}
		
		if ( exists $entry->{relationships}->{childrenSteps}->{data} &&
		     ref( $entry->{relationships}->{childrenSteps}->{data} ) eq 'ARRAY' ) {
			# "children" are segments within a programme
			my @childEntries = @{ $entry->{relationships}->{childrenSteps}->{data} };
			foreach my $childEntry ( @childEntries ) {
				if (exists $childEntry->{type} && $childEntry->{type} eq 'steps' &&
				    exists $childEntry->{id} ) {
					#main::DEBUGLOG && $log->is_debug && $log->debug("Child found: $childEntry->{id}");
					push @proglinkssegments, $childEntry->{id};
				}
			}
		}

		if ( (!exists $progInfo{'img'} || $progInfo{'img'} eq '') && exists $entry->{attributes}->{visuals} ){
			$progInfo{'img'} = getcover($entry->{attributes}->{visuals}, $station, '');
		}

		if ( (!exists $progInfo{'img'} || $progInfo{'img'} eq '') && exists $entry->{attributes} ){	# Not found so try up one level
			$progInfo{'img'} = getcover($entry->{attributes}, $station, '');
		}

		# Try diffusion
		if ( (!exists $progInfo{'img'} || $progInfo{'img'} eq '') && $diffusionid ne '' && exists $included_hash{$diffusionid}->{attributes}->{visuals} ){
			$progInfo{'img'} = getcover($included_hash{$diffusionid}->{attributes}->{visuals}, $station, '');
		}

		if ( (!exists $progInfo{'img'} || $progInfo{'img'} eq '') && $diffusionid ne '' && exists $included_hash{$diffusionid}->{attributes} ){
			$progInfo{'img'} = getcover($included_hash{$diffusionid}->{attributes}, $station, '');
		}

		# Try show
		if ( (!exists $progInfo{'img'} || $progInfo{'img'} eq '') && $progid ne '' && exists $included_hash{$progid}->{attributes}->{visuals} ){
			$progInfo{'img'} = getcover($included_hash{$progid}->{attributes}->{visuals}, $station, '');
		}

		if ( (!exists $progInfo{'img'} || $progInfo{'img'} eq '') && $progid ne '' && exists $included_hash{$progid}->{attributes} ){
			$progInfo{'img'} = getcover($included_hash{$progid}->{attributes}, $station, '');
		}

		foreach my $streamInfo ( @{$progstreamset} ){
			$dumped = Dumper $streamInfo;
			#main::DEBUGLOG && $log->is_debug && $log->debug("streamInfo-x: $dumped");
			
			if ( exists $included_hash{ $streamInfo->{id} } ){
				if ( exists $included_hash{ $streamInfo->{id} }->{attributes}->{url} &&
				     $included_hash{ $streamInfo->{id} }->{attributes}->{url} ne "" ){
					$progstreamurl = $included_hash{ $streamInfo->{id} }->{attributes}->{url};
					push @streamUrls, $progstreamurl;
					#main::INFOLOG && $log->is_info && $log->info("$station - Found stream url: $progstreamurl");
				} else {
					# Not found here so see if pointer to elsewhere
					#$dumped = Dumper $included_hash{ $progInfo->{id} };
					#main::DEBUGLOG && $log->is_debug && $log->debug("dump3: $dumped");
					my $thisthis = $streamInfo->{id};
					# print("Now looking at: $thisthis\n");
					if ( exists $included_hash{ $thisthis } && exists $included_hash{ $thisthis }->{relationships}->{manifestations}->{data} &&
					     ref $included_hash{ $thisthis }->{relationships}->{manifestations}->{data} eq 'ARRAY' ){
						#main::DEBUGLOG && $log->is_debug && $log->debug("trying3: $thisthis");
						foreach my $deeptry ( @{ $included_hash{ $thisthis }->{relationships}->{manifestations}->{data} } ){
							if ( exists $included_hash{ $deeptry->{id} }->{attributes}->{url} &&
							     $included_hash{ $deeptry->{id} }->{attributes}->{url} ne "" ){
								$progstreamurl = $included_hash{ $deeptry->{id} }->{attributes}->{url};
								push @streamUrls, $progstreamurl;
								$progInfo{'episodetitle'} = $included_hash{ $deeptry->{id} }->{attributes}->{title} if exists $included_hash{ $deeptry->{id} }->{attributes}->{title} && $included_hash{ $deeptry->{id} }->{attributes}->{title} ne '';
								#main::DEBUGLOG && $log->is_debug && $log->debug("$station - Deep found stream url: $progstreamurl - title: $progInfo{'episodetitle'}");
							}
						}
					}									
				}
			}
		}	# end loop through @progstreamset
		
		$progInfo{'streamurls'} = [@streamUrls];
		
		main::DEBUGLOG && $log->is_debug && $log->debug("-prog: $progInfo{'title'} / $progInfo{'episodetitle'}");
		
		my $count = scalar @proglinksbroadcast;
		#main::DEBUGLOG && $log->is_debug && $log->debug("Found $count broadcast links");
		
		@{$progInfo{'proglinksbroadcast'}} = @proglinksbroadcast;
		@{$progInfo{'proglinkssegments'}} = @proglinkssegments;
		$progInfo{'progstreamset'} = $progstreamset;
		
		$progInfo{'datapresent'} = 1;
		
		$dumped = Dumper \%progInfo;
		#main::DEBUGLOG && $log->is_debug && $log->debug("__getItemDetails return: $dumped");
		return %progInfo;
	};
	
	
	my $hiResTime = getLocalAdjustedTime;
	
	my @scheduleNodes = ();
	my %thisProg = ();

	my $hidenoaudio = $prefs->get('hidenoaudio');
	my $hidethis = false;
	my $scheduleflatten = $prefs->get('scheduleflatten');
	
	if (defined($content) && $content ne ''){
	
		main::DEBUGLOG && $log->is_debug && $log->debug("About to parse schedule");

		my $perl_data = eval { from_json( $content ) };

		#$dumped =  Dumper $content;
		#$dumped =~ s/\n {44}/\n/g;   
		# print $dumped;
		#main::DEBUGLOG && $log->is_debug && $log->debug("Content: $dumped");

		if (ref($perl_data) ne "ARRAY" && exists $perl_data->{'data'} && ref($perl_data->{'data'}) eq "ARRAY" &&
		    exists $perl_data->{'data'}[0]{attributes} &&
		    exists $perl_data->{'included'} && ref($perl_data->{'included'}) eq "ARRAY") {
			# Looks like programme schedule
			@data = @{ $perl_data->{'data'} };
			# $dumped =  Dumper @data;
			# print $dumped;
			@included = @{ $perl_data->{'included'} };
			%data_hash = ();
			%included_hash = ();

			foreach my $entry (@data){
				if ( exists $entry->{id} ) {
					$data_hash{$entry->{id}} = $entry;
				}
			}

			#$dumped = Dumper \%data_hash;
			#print("datahash: $dumped");
			
			foreach my $entry (@included){
				if ( exists $entry->{id} ) {
					$included_hash{$entry->{id}} = $entry;
				}
			}
		
			foreach my $dataentry (@data){
				# Go through the source data as an array (rather than the created hashes) because the source is sorted by start time
				# $dumped = Dumper $dataentry->{atttributes};
				# print $dumped;
			
				if (exists $dataentry->{type} && $dataentry->{type} eq 'steps' &&
				    exists $dataentry->{attributes}) {
					my $attributes = $dataentry->{attributes};
					
					my @progstreamset = ();
					# Arrays of references to data elsewhere in the structure
					my @proglinksbroadcast = ();
					my @proglinkssegments = ();
					my @proglinks = ();
					
					%thisProg = ();

					%thisProg = $__getItemDetails->( $dataentry );
					$thisProg{'isShow'} = 1;	# This is a new show (not a segment)
					
					@progstreamset = @{$thisProg{'progstreamset'}};
					
					$dumped = Dumper \@progstreamset;
					#main::DEBUGLOG && $log->is_debug && $log->debug("progstreamset: $dumped");
					
					if ( exists $thisProg{'proglinkshow'} || scalar @{$thisProg{'proglinkssegments'}} > 0){
						# If programme link or segments found
						#if ( $thisProg{'datapresent'} == 1 && (scalar @progstreamset > 0 || !$hidenoaudio )) {
						if ( $thisProg{'datapresent'} == 1 ) {
							#main::INFOLOG && $log->is_info && $log->info("$station - Found prog $thisProg{'title'} / $thisProg{'episodetitle'} at $thisProg{'start'}");
							push @scheduleNodes, {%thisProg};
							$thisProg{'datapresent'} = 0;
							$thisProg{'isShow'} = 0;	# Show pushed - so anything else is a segment
						} else {
							# no streams and asked to be hidden
							if ( $thisProg{'datapresent'} == 1 ){
								#main::DEBUGLOG && $log->is_debug && $log->debug("$station - Hiding because no streams $thisProg{'title'} - at $thisProg{'start'}");
							} else {
								#main::DEBUGLOG && $log->is_debug && $log->debug("$station - Skipping because already handled $thisProg{'title'} - at $thisProg{'start'}");
							}
						}
						
					} else {
						# No show links found for this item
						main::DEBUGLOG && $log->is_debug && $log->debug("Failed to find links in this programme $thisProg{'episodetitle'}");
					}
					
					# Now go through the segments
					
					my @segmentNodes = ();
					
					foreach my $segment (@{$thisProg{'proglinkssegments'}}){
						if ( exists $included_hash{$segment} ){
							#main::DEBUGLOG && $log->is_debug && $log->debug("segment: $segment");
							my $savedTitle = $thisProg{'title'};
							my $savedEpisodeTitle = $thisProg{'episodetitle'};
							
							%thisProg = $__getItemDetails->( $included_hash{$segment} );
							
							if ( $savedTitle ne '' ){
								$thisProg{'title'} = $savedTitle;
							} elsif ( $savedEpisodeTitle ne '' ){
								$thisProg{'title'} = $savedEpisodeTitle;
							}
							$thisProg{'isShow'} = 0;	# This is a segment (not a show)
							#main::INFOLOG && $log->is_info && $log->info("$station - Found segment $thisProg{'title'} / $thisProg{'episodetitle'} at $thisProg{'start'}");
							#push @scheduleNodes, {%thisProg};
							push @segmentNodes, {%thisProg};
						} else {
							main::INFOLOG && $log->is_info && $log->info("segment: $segment does not exists - possibly a song with no details available");
						}
					}
					
					if (scalar @segmentNodes > 0){
						# Some segments found ... but have seen from real data that the original array is not necessarily in time order
						# so sort it
						my @sortedNodes = sort { $a->{start} <=> $b->{start} } @segmentNodes;
						push @scheduleNodes, @sortedNodes;
					}
				}
			}	# end loop through @data
		} else {
			# Expected data not present - could be a temporary comms error or they have changed their data structure
			main::INFOLOG && $log->is_info && $log->info("$station - Failed to find expected arrays in received data");
		}

	}
	

	my $bound = (scalar @scheduleNodes)-1;
	my $menucounter = 0;

	for my $i (0..$bound) {

		$hidethis = false;
		%thisProg = %{$scheduleNodes[$i]};

		#$dumped = Dumper \%thisProg;
		#main::DEBUGLOG && $log->is_debug && $log->debug("$station - progdata - $dumped");
		#main::DEBUGLOG && $log->is_debug && $log->debug("$station - Adding to menu - $thisProg{'title'}");

		my $streamurls_ref = $thisProg{'streamurls'};
		
		if ( (defined($streamurls_ref) && scalar @$streamurls_ref > 0) || $thisProg{'isShow'} || !$hidenoaudio ) {

			my $prefix = strftime("%H:%M",localtime($thisProg{'start'}));
			my $name = $thisProg{'title'};
			#my $name = strftime("%H:%M",localtime($thisProg{'start'})) . ' ' . $thisProg{'title'};
			my $episodetitle = '';

			if ( $thisProg{'episodetitle'} ne '' && lc($thisProg{'episodetitle'}) ne lc($thisProg{'title'})){
				$episodetitle = ' - '.$thisProg{'episodetitle'}
			}
			
			my $suffix = '';			
			if ( !defined($streamurls_ref) || scalar @$streamurls_ref == 0 ){
				# No stream URLs (might be available later)
				$suffix .= ' - '.string('PLUGIN_RADIOFRANCE_SCHEDULE_NOTAVAILABLE');
			} else {
				#main::DEBUGLOG && $log->is_debug && $log->debug("streamurl: $thisProg{'streamurls'}[0]");
			}

			#main::DEBUGLOG && $log->is_debug && $log->debug("$station - Adding $thisProg{'isShow'} to menu - $name");
			
			if ( $thisProg{'isShow'} || $scheduleflatten ){
				$menucounter = push @menuPrepare,
				{
					name => $prefix . ' '. $name . $episodetitle . $suffix,
					image => $thisProg{'img'},
					# url => '',
					# type => 'a',
					# on_select   => ''		  
				};
				
				if ( defined($streamurls_ref) && scalar @$streamurls_ref > 0 ){
					$menuPrepare[$menucounter-1]->{url} = $thisProg{'streamurls'}[0];
					$menuPrepare[$menucounter-1]->{type} = 'audio';
					$menuPrepare[$menucounter-1]->{on_select}  = 'play';
				}
			} else {
				# Unflattened segment ... so add it to the previous show (if there was one)
				my $submenu = ();
				my %segment = ();
				my $root;
				
				%segment = (name => $prefix . $episodetitle . $suffix,
					    image => $thisProg{'img'},
					    # url => '',
					    # type => 'a',
					    # on_select => ''
				);
				
				if ( defined($streamurls_ref) && scalar @$streamurls_ref > 0 ){
					$segment{url} = $thisProg{'streamurls'}[0];
					$segment{type} = 'audio';
					$segment{on_select}  = 'play';
				}

				if ( $menucounter > 0 ){
					if ( defined $menuPrepare[$menucounter-1]->{items} ){
						$submenu = $menuPrepare[$menucounter-1]->{items};	# Get the current set
					} else {
						# If there was not already an item then convert the root into first item
						# otherwise Jive and some skins will not show the nested items
						$root = $menuPrepare[$menucounter-1];
						push @$submenu, {%$root};
						delete $menuPrepare[$menucounter-1]->{url};	# Remove the parts that indicated it was playable
						delete $menuPrepare[$menucounter-1]->{type};
						delete $menuPrepare[$menucounter-1]->{on_select};
						
						if ( defined($streamurls_ref) && scalar @$streamurls_ref > 0 ){
							# There is a stream for this segment ... so remove confusing "not available" from parent (if present)
							my $oldSuffix = ' - '.string('PLUGIN_RADIOFRANCE_SCHEDULE_NOTAVAILABLE');
							$menuPrepare[$menucounter-1]->{name} =~ s/\Q$oldSuffix\E$//;
						}
					}
				
					push @$submenu, {%segment};
					$menuPrepare[$menucounter-1]->{items} = \@$submenu;
				} else {
					# Odd case ... no programmes yet but we have an episode (this happens sometimes with the overnight show on France Culture)
					$menucounter = push @menuPrepare, {%segment};
				}
			}
		}
	}


	# Second pass to tidy up
	$bound = (scalar @menuPrepare)-1;
	$menucounter = 0;

	for my $i2 (0..$bound) {
		if ( !defined $menuPrepare[$i2]->{url} && !defined $menuPrepare[$i2]->{items} && $hidenoaudio){
			#main::DEBUGLOG && $log->is_debug && $log->debug("Menu: Hiding because no url and subitems for: $menuPrepare[$i2]->{name}");
		} else {
			push @$menu, $menuPrepare[$i2];
		}
		
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("--_parseSchedule");
}



sub _getCachedMenu {
	my $url = shift;
	main::DEBUGLOG && $log->is_debug && $log->debug("++_getCachedMenu");

	my $cacheKey = $pluginName . ':' . md5_hex($url);

	if ( my $cachedMenu = $cache->get($cacheKey) ) {
		my $menu = ${$cachedMenu};
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu got cached menu");
		return $menu;
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug("--_getCachedMenu no cache");
		return;
	}
}


sub _cacheMenu {
	my ( $url, $menu, $seconds ) = @_;	
	main::DEBUGLOG && $log->is_debug && $log->debug("++_cacheMenu");
	my $cacheKey = $pluginName . ':' . md5_hex($url);
	$cache->set( $cacheKey, \$menu, $seconds );

	main::DEBUGLOG && $log->is_debug && $log->debug("--_cacheMenu");
	return;
}


sub toplevel {
	my ( $client, $callback, $args ) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug("++toplevel");


	my $menu = [
		{
			name	=> string('PLUGIN_RADIOFRANCE_LIVE'),
			image	=> 'plugins/RadioFrance/html/images/radiofrance_svg.png',
			items	=> [
			{
				name	=> 'France Inter',
				image	=> $icons->{franceinter},
				items	=> [
					{
						name	=> 'France Inter',
						image	=> $icons->{franceinter},
						items	=> [
							{
								name	=> 'France Inter (HLS)',
								type	=> 'audio',
								icon	=> $icons->{franceinter},
								url	=> 'https://stream.radiofrance.fr/franceinter/franceinter.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Inter (AAC)',
								type	=> 'audio',
								icon	=> $icons->{franceinter},
								url	=> 'http://icecast.radiofrance.fr/franceinter-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Inter (MP3)',
								type	=> 'audio',
								icon	=> $icons->{franceinter},
								url	=> 'http://icecast.radiofrance.fr/franceinter-midfi.mp3',
								on_select	=> 'play'
							},
						],
					},
					{
						name	=> 'La musique d\'Inter',
						image	=> $icons->{franceinterlamusiqueinter},
						items	=> [
							{
								name	=> 'La musique d\'Inter (HLS)',
								type	=> 'audio',
								icon	=> $icons->{franceinterlamusiqueinter},
								url	=> 'https://stream.radiofrance.fr/franceinterlamusiqueinter/franceinterlamusiqueinter.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'La musique d\'Inter (AAC)',
								type	=> 'audio',
								icon	=> $icons->{franceinterlamusiqueinter},
								url	=> 'https://icecast.radiofrance.fr/franceinterlamusiqueinter-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'La musique d\'Inter (MP3)',
								type	=> 'audio',
								icon	=> $icons->{franceinterlamusiqueinter},
								url	=> 'https://icecast.radiofrance.fr/franceinterlamusiqueinter-midfi.mp3',
								on_select	=> 'play'
							}
						]
					}
				]
			},{
					name => 'FIP',
					image => $icons->{fipradio},
					items => [
						{
							name => 'FIP',
							image => $icons->{fipradio},
							items => [
								{
									name        => 'FIP (HLS)',
									type        => 'audio',
									icon        => $icons->{fipradio},
									url         => 'https://stream.radiofrance.fr/fip/fip.m3u8',
									on_select   => 'play'
								},
								{
									name        => 'FIP (AAC)',
									type        => 'audio',
									icon        => $icons->{fipradio},
									url         => 'http://icecast.radiofrance.fr/fip-hifi.aac',
									on_select   => 'play'
								},
								{
									name        => 'FIP (MP3)',
									type        => 'audio',
									icon        => $icons->{fipradio},
									url         => 'http://icecast.radiofrance.fr/fip-midfi.mp3',
									on_select   => 'play'
								},
							],
						},{
							name	=> 'Rock',
							image	=> $icons->{fiprock},
							items	=> [
								{
									name	=> 'FIP Rock (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fiprock},
									url	=> 'https://stream.radiofrance.fr/fiprock/fiprock.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Rock (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fiprock},
									url	=> 'http://icecast.radiofrance.fr/fiprock-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Rock (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fiprock},
									url	=> 'http://icecast.radiofrance.fr/fiprock-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Jazz',
							image	=> $icons->{fipjazz},
							items	=> [
								{
									name	=> 'FIP Jazz (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipjazz},
									url	=> 'https://stream.radiofrance.fr/fipjazz/fipjazz.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Jazz (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipjazz},
									url	=> 'http://icecast.radiofrance.fr/fipjazz-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Jazz (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipjazz},
									url	=> 'http://icecast.radiofrance.fr/fipjazz-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Groove',
							image	=> $icons->{fipgroove},
							items	=> [
								{
									name	=> 'FIP Groove (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipgroove},
									url	=> 'https://stream.radiofrance.fr/fipgroove/fipgroove.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Groove (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipgroove},
									url	=> 'http://icecast.radiofrance.fr/fipgroove-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Groove (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipgroove},
									url	=> 'http://icecast.radiofrance.fr/fipgroove-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Metal',
							image	=> $icons->{fipmetal},
							items	=> [
								{
									name	=> 'FIP Metal (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipmetal},
									url	=> 'https://stream.radiofrance.fr/fipmetal/fipmetal.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Metal (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipmetal},
									url	=> 'http://icecast.radiofrance.fr/fipmetal-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Metal (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipmetal},
									url	=> 'http://icecast.radiofrance.fr/fipmetal-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Hip-Hop',
							image	=> $icons->{fiphiphop},
							items	=> [
								{
									name	=> 'FIP Hip-Hop (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fiphiphop},
									url	=> 'https://stream.radiofrance.fr/fiphiphop/fiphiphop.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Hip-Hop (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fiphiphop},
									url	=> 'http://icecast.radiofrance.fr/fiphiphop-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Hip-Hop (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fiphiphop},
									url	=> 'http://icecast.radiofrance.fr/fiphiphop-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Electro',
							image	=> $icons->{fipelectro},
							items	=> [
								{
									name	=> 'FIP Electro (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipelectro},
									url	=> 'https://stream.radiofrance.fr/fipelectro/fipelectro.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Electro (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipelectro},
									url	=> 'http://icecast.radiofrance.fr/fipelectro-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Electro (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipelectro},
									url	=> 'http://icecast.radiofrance.fr/fipelectro-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Pop',
							image	=> $icons->{fippop},
							items	=> [
								{
									name	=> 'FIP Pop (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fippop},
									url	=> 'https://stream.radiofrance.fr/fippop/fippop.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Pop (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fippop},
									url	=> 'http://icecast.radiofrance.fr/fippop-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Pop (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fippop},
									url	=> 'http://icecast.radiofrance.fr/fippop-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Monde',
							image	=> $icons->{fipmonde},
							items	=> [
								{
									name	=> 'FIP Monde (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipmonde},
									url	=> 'https://stream.radiofrance.fr/fipworld/fipworld.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Monde (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipmonde},
									url	=> 'http://icecast.radiofrance.fr/fipworld-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Monde (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipmonde},
									url	=> 'http://icecast.radiofrance.fr/fipworld-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Reggae',
							image	=> $icons->{fipreggae},
							items	=> [
								{
									name	=> 'FIP Reggae (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipreggae},
									url	=> 'https://stream.radiofrance.fr/fipreggae/fipreggae.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Reggae (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipreggae},
									url	=> 'http://icecast.radiofrance.fr/fipreggae-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Reggae (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipreggae},
									url	=> 'http://icecast.radiofrance.fr/fipreggae-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Nouveau',
							image	=> $icons->{fipnouveau},
							items	=> [
								{
									name	=> 'FIP Nouveau (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipnouveau},
									url	=> 'https://stream.radiofrance.fr/fipnouveautes/fipnouveautes.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Nouveau (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipnouveau},
									url	=> 'http://icecast.radiofrance.fr/fipnouveautes-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Nouveau (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipnouveau},
									url	=> 'http://icecast.radiofrance.fr/fipnouveautes-midfi.mp3',
									on_select	=> 'play'
								},
							]
						},{
							name	=> 'Sacré français !',
							image	=> $icons->{fipsacre},
							items	=> [
								{
									name	=> 'FIP Sacré français ! (HLS)',
									type	=> 'audio',
									icon	=> $icons->{fipsacre},
									url	=> 'https://stream.radiofrance.fr/fipsacrefrancais/fipsacrefrancais.m3u8',
									on_select	=> 'play'
								},{
									name	=> 'FIP Sacré français ! (AAC)',
									type	=> 'audio',
									icon	=> $icons->{fipsacre},
									url	=> 'http://icecast.radiofrance.fr/fipsacrefrancais-hifi.aac',
									on_select	=> 'play'
								},{
									name	=> 'FIP Sacré français ! (MP3)',
									type	=> 'audio',
									icon	=> $icons->{fipsacre},
									url	=> 'http://icecast.radiofrance.fr/fipsacrefrancais-midfi.mp3',
									on_select	=> 'play'
								},
							]
						}
				]
			},{
				name	=> 'France Musique',
				image	=> $icons->{francemusique},
				items	=> [
					{
					name	=> 'France Musique',
					image	=> $icons->{francemusique},
					items	=> [
						{
							name	=> 'France Musique (HLS)',
							type	=> 'audio',
							icon	=> $icons->{francemusique},
							url	=> 'https://stream.radiofrance.fr/francemusique/francemusique.m3u8',
							on_select	=> 'play'
						},{
							name	=> 'France Musique (AAC)',
							type	=> 'audio',
							icon	=> $icons->{francemusique},
							url	=> 'http://icecast.radiofrance.fr/francemusique-hifi.aac',
							on_select	=> 'play'
						},{
							name	=> 'France Musique (MP3)',
							type	=> 'audio',
							icon	=> $icons->{francemusique},
							url	=> 'http://icecast.radiofrance.fr/francemusique-midfi.mp3',
							on_select	=> 'play'
						},
					]
					},{
						name	=> 'Classique Easy',
						image	=> $icons->{fmclassiqueeasy},
						items	=> [
							{
								name	=> 'France Musique Classique Easy (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmclassiqueeasy},
								url	=> 'https://stream.radiofrance.fr/francemusiqueeasyclassique/francemusiqueeasyclassique.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Classique Easy (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmclassiqueeasy},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueeasyclassique-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Classique Easy (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmclassiqueeasy},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueeasyclassique-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Opéra',
						image	=> $icons->{fmopera},
						items	=> [
							{
								name	=> 'France Musique Opéra (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmopera},
								url	=> 'https://stream.radiofrance.fr/francemusiqueopera/francemusiqueopera.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Opéra (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmopera},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueopera-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Opéra (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmopera},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueopera-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'La Baroque',
						image	=> $icons->{fmbaroque},
						items	=> [
							{
								name	=> 'France Musique La Baroque (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmbaroque},
								url	=> 'https://stream.radiofrance.fr/francemusiquebaroque/francemusiquebaroque.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique La Baroque (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmbaroque},
								url	=> 'http://icecast.radiofrance.fr/francemusiquebaroque-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique La Baroque (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmbaroque},
								url	=> 'http://icecast.radiofrance.fr/francemusiquebaroque-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Classique Plus',
						image	=> $icons->{fmclassiqueplus},
						items	=> [
							{
								name	=> 'France Musique Classique Plus (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmclassiqueplus},
								url	=> 'https://stream.radiofrance.fr/francemusiqueclassiqueplus/francemusiqueclassiqueplus.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Classique Plus (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmclassiqueplus},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueclassiqueplus-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Classique Plus (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmclassiqueplus},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueclassiqueplus-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Concerts Radio France',
						image	=> $icons->{fmconcertsradiofrance},
						items	=> [
							{
								name	=> 'France Musique Concerts Radio France (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmconcertsradiofrance},
								url	=> 'https://stream.radiofrance.fr/francemusiqueconcertsradiofrance/francemusiqueconcertsradiofrance.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Concerts Radio France (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmconcertsradiofrance},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueconcertsradiofrance-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Concerts Radio France (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmconcertsradiofrance},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueconcertsradiofrance-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'La Jazz',
						image	=> $icons->{fmlajazz},
						items	=> [
							{
								name	=> 'France Musique La Jazz (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmlajazz},
								url	=> 'https://stream.radiofrance.fr/francemusiquelajazz/francemusiquelajazz.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique La Jazz (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmlajazz},
								url	=> 'http://icecast.radiofrance.fr/francemusiquelajazz-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique La Jazz (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmlajazz},
								url	=> 'http://icecast.radiofrance.fr/francemusiquelajazz-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'La Contemporaine',
						image	=> $icons->{fmlacontemporaine},
						items	=> [
							{
								name	=> 'France Musique La Contemporaine (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmlacontemporaine},
								url	=> 'https://stream.radiofrance.fr/francemusiquelacontemporaine/francemusiquelacontemporaine.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique La Contemporaine (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmlacontemporaine},
								url	=> 'http://icecast.radiofrance.fr/francemusiquelacontemporaine-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique La Contemporaine (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmlacontemporaine},
								url	=> 'http://icecast.radiofrance.fr/francemusiquelacontemporaine-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Piano Zen',
						image	=> $icons->{fmpianozen},
						items	=> [
							{
								name	=> 'France Musique Piano Zen (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmpianozen},
								url	=> 'https://stream.radiofrance.fr/francemusiquepianozen/francemusiquepianozen.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Piano Zen (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmpianozen},
								url => 'http://icecast.radiofrance.fr/francemusiquepianozen-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Piano Zen (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmpianozen},
								url	=> 'http://icecast.radiofrance.fr/francemusiquepianozen-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Ocora Musiques du Monde',
						image	=> $icons->{fmocoramonde},
						items	=> [
							{
								name	=> 'France Musique Ocora Musiques du Monde (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmocoramonde},
								url	=> 'https://stream.radiofrance.fr/francemusiqueocoramonde/francemusiqueocoramonde.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Ocora Musiques du Monde (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmocoramonde},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueocoramonde-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Ocora Musiques du Monde (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmocoramonde},
								url	=> 'http://icecast.radiofrance.fr/francemusiqueocoramonde-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Films',
						image	=> $icons->{fmlabo},
						items	=> [
							{
								name	=> 'France Musique Films (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fmlabo},
								url	=> 'https://stream.radiofrance.fr/francemusiquelabo/francemusiquelabo.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Films (AAC)',
								type	=> 'audio',
								icon	=> $icons->{fmlabo},
								url	=> 'http://icecast.radiofrance.fr/francemusiquelabo-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'France Musique Films (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fmlabo},
								url	=> 'http://icecast.radiofrance.fr/francemusiquelabo-midfi.mp3',
								on_select	=> 'play'
							},
						]
					}
				]
			},{
				name	=> 'Mouv\'',
				image	=> $icons->{mouv},
				items	=> [
					{
						name	=> 'Mouv\'',
						icon	=> $icons->{mouv},
						items	=> [
							{
								name	=> 'Mouv\' (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouv},
								url	=> 'https://stream.radiofrance.fr/mouv/mouv.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouv},
								url	=> 'http://icecast.radiofrance.fr/mouv-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouv},
								url	=> 'http://icecast.radiofrance.fr/mouv-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Rap Français',
						image	=> $icons->{mouvrapfr},
						items	=> [
							{
								name	=> 'Mouv\' Rap Français (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvrapfr},
								url	=> 'https://stream.radiofrance.fr/mouvrapfr/mouvrapfr.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Rap Français (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvrapfr},
								url	=> 'http://icecast.radiofrance.fr/mouvrapfr-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Rap Français (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvrapfr},
								url	=> 'http://icecast.radiofrance.fr/mouvrapfr-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> '100%Mix',
						image	=> $icons->{mouv100mix},
						items	=> [
							{
								name	=> '100%Mix (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouv100mix},
								url	=> 'https://stream.radiofrance.fr/mouv100p100mix/mouv100p100mix.m3u8',
								on_select	=> 'play'
							},{
								name	=> '100%Mix (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouv100mix},
								url	=> 'http://icecast.radiofrance.fr/mouv100p100mix-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> '100%Mix (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouv100mix},
								url	=> 'http://icecast.radiofrance.fr/mouv100p100mix-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Classics',
						image	=> $icons->{mouvclassics},
						items	=> [
							{
								name	=> 'Mouv\' Classics (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvclassics},
								url	=> 'https://stream.radiofrance.fr/mouvclassics/mouvclassics.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Classics (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvclassics},
								url	=> 'http://icecast.radiofrance.fr/mouvclassics-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Classics (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvclassics},
								url	=> 'http://icecast.radiofrance.fr/mouvclassics-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Kids\'n Family',
						image	=> $icons->{mouvkidsnfamily},
						items	=> [
							{
								name	=> 'Mouv\' Kids\'n Family (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvkidsnfamily},
								url	=> 'https://stream.radiofrance.fr/mouvkidsnfamily/mouvkidsnfamily.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Kids\'n Family (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvkidsnfamily},
								url	=> 'http://icecast.radiofrance.fr/mouvkidsnfamily-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Kids\'n Family (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvkidsnfamily},
								url	=> 'http://icecast.radiofrance.fr/mouvkidsnfamily-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Rap US',
						image	=> $icons->{mouvrapus},
						items	=> [
							{
								name	=> 'Mouv\' Rap US (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvrapus},
								url	=> 'https://stream.radiofrance.fr/mouvrapus/mouvrapus.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Rap US (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvrapus},
								url	=> 'http://icecast.radiofrance.fr/mouvrapus-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Rap US (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvrapus},
								url	=> 'http://icecast.radiofrance.fr/mouvrapus-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'R\'n\'B',
						image	=> $icons->{mouvrnb},
						items	=> [
							{
								name	=> 'Mouv\' R\'n\'B (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvrnb},
								url	=> 'https://stream.radiofrance.fr/mouvrnb/mouvrnb.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' R\'n\'B (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvrnb},
								url	=> 'http://icecast.radiofrance.fr/mouvrnb-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' R\'n\'B (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvrnb},
								url	=> 'http://icecast.radiofrance.fr/mouvrnb-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Dancehall',
						image	=> $icons->{mouvdancehall},
						items	=> [
							{
								name	=> 'Mouv\' Dancehall (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvdancehall},
								url	=> 'https://stream.radiofrance.fr/mouvdancehall/mouvdancehall.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Dancehall (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvdancehall},
								url	=> 'http://icecast.radiofrance.fr/mouvdancehall-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Dancehall (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvdancehall},
								url	=> 'http://icecast.radiofrance.fr/mouvdancehall-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Sans Blabla',
						image	=> $icons->{mouvsansblabla},
						items	=> [
							{
								name	=> 'Mouv\' Sans Blabla (HLS)',
								type	=> 'audio',
								icon	=> $icons->{mouvsansblabla},
								url	=> 'https://stream.radiofrance.fr/mouvsansblabla/mouvsansblabla.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Sans Blabla (AAC)',
								type	=> 'audio',
								icon	=> $icons->{mouvsansblabla},
								url	=> 'http://icecast.radiofrance.fr/mouvsansblabla-hifi.aac',
								on_select	=> 'play'
							},{
								name	=> 'Mouv\' Sans Blabla (MP3)',
								type	=> 'audio',
								icon	=> $icons->{mouvsansblabla},
								url	=> 'http://icecast.radiofrance.fr/mouvsansblabla-midfi.mp3',
								on_select	=> 'play'
							},
						]
					}
					]
			},{
			
				name	=> 'franceinfo',
				image	=> $icons->{franceinfo},
				items	=> [
					{
						name	=> 'franceinfo (HLS)',
						type	=> 'audio',
						icon	=> $icons->{franceinfo},
						url	=> 'https://stream.radiofrance.fr/franceinfo/franceinfo.m3u8',
						on_select	=> 'play'
					},{
						name	=> 'franceinfo (AAC)',
						type	=> 'audio',
						icon	=> $icons->{franceinfo},
						url	=> 'http://icecast.radiofrance.fr/franceinfo-hifi.aac',
						on_select	=> 'play'
					},{
						name	=> 'franceinfo (MP3)',
						type	=> 'audio',
						icon	=> $icons->{franceinfo},
						url	=> 'http://icecast.radiofrance.fr/franceinfo-midfi.mp3',
						on_select	=> 'play'
					},
				]
			},{
				name	=> 'France Culture',
				image	=> $icons->{franceculture},
				items	=> [
					{
						name	=> 'France Culture (HLS)',
						type	=> 'audio',
						icon	=> $icons->{franceculture},
						url	=> 'https://stream.radiofrance.fr/franceculture/franceculture.m3u8',
						on_select	=> 'play'
					},{
						name	=> 'France Culture (AAC)',
						type	=> 'audio',
						icon	=> $icons->{franceculture},
						url	=> 'http://icecast.radiofrance.fr/franceculture-hifi.aac',
						on_select	=> 'play'
					},{
						name	=> 'France Culture (MP3)',
						type	=> 'audio',
						icon	=> $icons->{franceculture},
						url	=> 'http://icecast.radiofrance.fr/franceculture-midfi.mp3',
						on_select	=> 'play'
					},
				]
			},{
				name	=> 'ici',
				#image	=> 'https://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-bleu.png',
				image	=> 'https://www.radiofrance.fr/client/immutable/assets/francebleu-seosquare.CfwKvmMQ.png',
				items	=> [
					{
						name	=> '100% Chanson Française',
						icon	=> $icons->{fb100chanson},
						items	=> [
							{
							name	=> '100% Chanson Française',
							icon	=> $icons->{fb100chanson},
								name	=> 'ici 100% Chanson Française (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fb100chanson},
								url	=> 'https://stream.radiofrance.fr/fbchansonfrancaise/fbchansonfrancaise_lofi.m3u8',
								on_select	=> 'play'
							},
							{
							name	=> '100% Chanson Française',
							icon	=> $icons->{fb100chanson},
								name	=> 'ici 100% Chanson Française (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fb100chanson},
								url	=> 'http://icecast.radiofrance.fr/fbchansonfrancaise-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Alsace',
						icon	=> $icons->{fbalsace},
						items	=> [
							{
							name	=> 'Alsace',
							icon	=> $icons->{fbalsace},
								name	=> 'ici Alsace (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbalsace},
								url	=> 'https://stream.radiofrance.fr/fbalsace/fbalsace.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Alsace (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbalsace},
								url	=> 'http://direct.francebleu.fr/live/fbalsace-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Armorique',
						image	=> $icons->{fbarmorique},
						items	=> [
							{
								name	=> 'ici Armorique (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbarmorique},
								url	=> 'https://stream.radiofrance.fr/fbarmorique/fbarmorique.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Armorique (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbarmorique},
								url	=> 'http://direct.francebleu.fr/live/fbarmorique-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Auxerre',
						image	=> $icons->{fbauxerre},
						items	=> [
							{
								name	=> 'ici Auxerre (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbauxerre},
								url	=> 'https://stream.radiofrance.fr/fbauxerre/fbauxerre.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Auxerre (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbauxerre},
								url	=> 'http://direct.francebleu.fr/live/fbauxerre-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Azur',
						image	=> $icons->{fbazur},
						items	=> [
							{
								name	=> 'ici Azur (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbazur},
								url	=> 'https://stream.radiofrance.fr/fbazur/fbazur.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Azur (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbazur},
								url	=> 'http://direct.francebleu.fr/live/fbazur-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Béarn',
						image	=> $icons->{fbbearn},
						items	=> [
							{
								name	=> 'ici Béarn (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbbearn},
								url	=> 'https://stream.radiofrance.fr/fbbearn/fbbearn.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Béarn (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbbearn},
								url	=> 'http://direct.francebleu.fr/live/fbbearn-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Belfort-Montbéliard',
						image	=> $icons->{fbbelfort},
						items	=> [
							{
								name	=> 'ici Belfort-Montbéliard (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbbelfort},
								url	=> 'https://stream.radiofrance.fr/fbbelfort/fbbelfort.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Belfort-Montbéliard (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbbelfort},
								url	=> 'http://direct.francebleu.fr/live/fbbelfort-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Berry',
						image	=> $icons->{fbberry},
						items	=> [
							{
								name	=> 'ici Berry (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbberry},
								url	=> 'https://stream.radiofrance.fr/fbberry/fbberry.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Berry (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbberry},
								url	=> 'http://direct.francebleu.fr/live/fbberry-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Besançon',
						image	=> $icons->{fbbesancon},
						items	=> [
							{
								name	=> 'ici Besançon (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbbesancon},
								url	=> 'https://stream.radiofrance.fr/fbbesancon/fbbesancon.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Besançon (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbbesancon},
							url	=> 'http://direct.francebleu.fr/live/fbbesancon-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Bourgogne',
						image	=> $icons->{fbbourgogne},
						items	=> [
							{
								name	=> 'ici Bourgogne (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbbourgogne},
								url	=> 'https://stream.radiofrance.fr/fbbourgogne/fbbourgogne.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Bourgogne (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbbourgogne},
								url	=> 'http://direct.francebleu.fr/live/fbbourgogne-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Breizh Izel',
						image	=> $icons->{fbbreizhizel},
						items	=> [
							{
								name	=> 'ici Breizh Izel (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbbreizhizel},
								url	=> 'https://stream.radiofrance.fr/fbbreizizel/fbbreizizel.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Breizh Izel (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbbreizhizel},
								url	=> 'http://direct.francebleu.fr/live/fbbreizizel-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Champagne-Ardenne',
						image	=> $icons->{fbchampagne},
						items	=> [
							{
								name	=> 'ici Champagne-Ardenne (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbchampagne},
								url	=> 'https://stream.radiofrance.fr/fbchampagne/fbchampagne.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Champagne-Ardenne (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbchampagne},
								url	=> 'http://direct.francebleu.fr/live/fbchampagne-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Cotentin',
						image	=> $icons->{fbcotentin},
						items	=> [
							{
								name	=> 'ici Cotentin (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbcotentin},
								url	=> 'https://stream.radiofrance.fr/fbcotentin/fbcotentin.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Cotentin (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbcotentin},
								url	=> 'http://direct.francebleu.fr/live/fbcotentin-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Creuse',
						image	=> $icons->{fbcreuse},
						items	=> [
							{
								name	=> 'ici Creuse (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbcreuse},
								url	=> 'https://stream.radiofrance.fr/fbcreuse/fbcreuse.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Creuse (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbcreuse},
								url	=> 'http://direct.francebleu.fr/live/fbcreuse-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Drôme Ardèche',
						image	=> $icons->{fbdromeardeche},
						items	=> [
							{
								name	=> 'ici Drôme Ardèche (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbdromeardeche},
								url	=> 'https://stream.radiofrance.fr/fbdromeardeche/fbdromeardeche.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Drôme Ardèche (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbdromeardeche},
								url	=> 'http://direct.francebleu.fr/live/fbdromeardeche-midfi.mp3',
								on_select	=> 'play'
							},
						]
						
						# Wrong logo 
					},{
						name	=> 'Elsass',
						image	=> $icons->{fbelsass},
						items	=> [
							{
								name	=> 'ici Elsass (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbelsass},
								url	=> 'https://stream.radiofrance.fr/fbelsass/fbelsass.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Elsass (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbelsass},
								url	=> 'http://direct.francebleu.fr/live/fbelsass-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Gard Lozère',
						image	=> $icons->{fbgardlozere},
						items	=> [
							{
								name	=> 'ici Gard Lozère (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbgardlozere},
								url	=> 'https://stream.radiofrance.fr/fbgardlozere/fbgardlozere.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Gard Lozère (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbgardlozere},
								url	=> 'http://direct.francebleu.fr/live/fbgardlozere-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Gascogne',
						image	=> $icons->{fbgascogne},
						items	=> [
							{
								name	=> 'ici Gascogne (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbgascogne},
								url	=> 'https://stream.radiofrance.fr/fbgascogne/fbgascogne.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Gascogne (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbgascogne},
								url	=> 'http://direct.francebleu.fr/live/fbgascogne-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Gironde',
						image	=> $icons->{fbgironde},
						items	=> [
							{
								name	=> 'ici Gironde (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbgironde},
								url	=> 'https://stream.radiofrance.fr/fbgironde/fbgironde.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Gironde (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbgironde},
								url	=> 'http://direct.francebleu.fr/live/fbgironde-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Hérault',
						image	=> $icons->{fbherault},
						items	=> [
							{
								name	=> 'ici Hérault (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbherault},
								url	=> 'https://stream.radiofrance.fr/fbherault/fbherault.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Hérault (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbherault},
								url	=> 'http://direct.francebleu.fr/live/fbherault-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Isère',
						image	=> $icons->{fbisere},
						items	=> [
							{
								name	=> 'ici Isère (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbisere},
								url	=> 'https://stream.radiofrance.fr/fbisere/fbisere.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Isère (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbisere},
								url	=> 'http://direct.francebleu.fr/live/fbisere-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'La Rochelle',
						image	=> $icons->{fblarochelle},
						items	=> [
							{
								name	=> 'ici La Rochelle (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fblarochelle},
								url	=> 'https://stream.radiofrance.fr/fblarochelle/fblarochelle.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici La Rochelle (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fblarochelle},
								url	=> 'http://direct.francebleu.fr/live/fblarochelle-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Limousin',
						image	=> $icons->{fblimousin},
						items	=> [
							{
								name	=> 'ici Limousin (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fblimousin},
								url	=> 'https://stream.radiofrance.fr/fblimousin/fblimousin.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Limousin (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fblimousin},
								url	=> 'http://direct.francebleu.fr/live/fblimousin-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Loire Océan',
						image	=> $icons->{fbloireocean},
						items	=> [
							{
								name	=> 'ici Loire Océan (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbloireocean},
								url	=> 'https://stream.radiofrance.fr/fbloireocean/fbloireocean.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Loire Océan (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbloireocean},
								url	=> 'http://direct.francebleu.fr/live/fbloireocean-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Lorraine Nord',
						image	=> $icons->{fblorrainenord},
						items	=> [
							{
								name	=> 'ici Lorraine Nord (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fblorrainenord},
								url	=> 'https://stream.radiofrance.fr/fblorrainenord/fblorrainenord.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Lorraine Nord (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fblorrainenord},
								url	=> 'http://direct.francebleu.fr/live/fblorrainenord-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Maine',
						image	=> $icons->{fbmaine},
						items	=> [
							{
								name	=> 'ici Maine (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbmaine},
								url	=> 'https://stream.radiofrance.fr/fbmaine/fbmaine.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Maine (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbmaine},
								url	=> 'http://direct.francebleu.fr/live/fbmaine-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Mayenne',
						image	=> $icons->{fbmayenne},
						items	=> [
							{
								name	=> 'ici Mayenne (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbmayenne},
								url	=> 'https://stream.radiofrance.fr/fbmayenne/fbmayenne.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Mayenne (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbmayenne},
								url	=> 'http://direct.francebleu.fr/live/fbmayenne-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Nord',
						image	=> $icons->{fbnord},
						items	=> [
							{
								name	=> 'ici Nord (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbnord},
								url	=> 'https://stream.radiofrance.fr/fbnord/fbnord.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Nord (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbnord},
								url	=> 'http://direct.francebleu.fr/live/fbnord-midfi.mp3',
								on_select	=> 'play'
							},
						]
						# Wrong logo and non-standard naming
					},{
						name	=> 'Normandie (Calvados - Orne)',
						image	=> $icons->{fbbassenormandie},
						items	=> [
							{
								name	=> 'ici Normandie (Calvados - Orne) (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbbassenormandie},
								url	=> 'https://stream.radiofrance.fr/fbbassenormandie/fbbassenormandie.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Normandie (Calvados - Orne) (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbbassenormandie},
								url	=> 'http://direct.francebleu.fr/live/fbbassenormandie-midfi.mp3',
								on_select	=> 'play'
							},
						]
						# Wrong logo and non-standard naming
					},{
						name	=> 'Normandie (Seine-Maritime - Eure)',
						image	=> $icons->{fbhautenormandie},
						items	=> [
							{
								name	=> 'ici Normandie (Seine-Maritime - Eure) (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbhautenormandie},
								url	=> 'https://stream.radiofrance.fr/fbhautenormandie/fbhautenormandie.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Normandie (Seine-Maritime - Eure) (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbhautenormandie},
								url	=> 'http://direct.francebleu.fr/live/fbhautenormandie-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Occitanie',
						image	=> $icons->{fbtoulouse},
						items	=> [
							{
								name	=> 'ici Occitanie (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbtoulouse},
								url	=> 'https://stream.radiofrance.fr/fbtoulouse/fbtoulouse.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Occitanie (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbtoulouse},
								url	=> 'http://direct.francebleu.fr/live/fbtoulouse-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Orléans',
						image	=> $icons->{fborleans},
						items	=> [
							{
								name	=> 'ici Orléans (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fborleans},
								url	=> 'https://stream.radiofrance.fr/fborleans/fborleans.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Orléans (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fborleans},
								url	=> 'http://direct.francebleu.fr/live/fborleans-midfi.mp3',
								on_select	=> 'play'
							},
						]
						# Special case - 107-1 = Paris
					},{
						name	=> 'Paris',
						image	=> $icons->{fbparis},
						items	=> [
							{
								name	=> 'ici Paris (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbparis},
								url	=> 'https://stream.radiofrance.fr/fb1071/fb1071.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Paris (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbparis},
								url	=> 'http://direct.francebleu.fr/live/fb1071-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Pays Basque',
						image	=> $icons->{fbpaysbasque},
						items	=> [
							{
								name	=> 'ici Pays Basque (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbpaysbasque},
								url	=> 'https://stream.radiofrance.fr/fbpaysbasque/fbpaysbasque.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Pays Basque (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbpaysbasque},
								url	=> 'http://direct.francebleu.fr/live/fbpaysbasque-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Pays d\'Auvergne',
						image	=> $icons->{fbpaysdauvergne},
						items	=> [
							{
								name	=> 'ici Pays d\'Auvergne (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbpaysdauvergne},
								url	=> 'https://stream.radiofrance.fr/fbpaysdauvergne/fbpaysdauvergne.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Pays d\'Auvergne (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbpaysdauvergne},
								url	=> 'http://direct.francebleu.fr/live/fbpaysdauvergne-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Pays de Savoie',
						image	=> $icons->{fbpaysdesavoie},
						items	=> [
							{
								name	=> 'ici Pays de Savoie (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbpaysdesavoie},
								url	=> 'https://stream.radiofrance.fr/fbpaysdesavoie/fbpaysdesavoie.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Pays de Savoie (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbpaysdesavoie},
								url	=> 'http://direct.francebleu.fr/live/fbpaysdesavoie-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Périgord',
						image	=> $icons->{fbperigord},
						items	=> [
							{
								name	=> 'ici Périgord (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbperigord},
								url	=> 'https://stream.radiofrance.fr/fbperigord/fbperigord.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Périgord (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbperigord},
								url	=> 'http://direct.francebleu.fr/live/fbperigord-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Picardie',
						image	=> $icons->{fbpicardie},
						items	=> [
							{
								name	=> 'ici Picardie (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbpicardie},
								url	=> 'https://stream.radiofrance.fr/fbpicardie/fbpicardie.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Picardie (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbpicardie},
								url	=> 'http://direct.francebleu.fr/live/fbpicardie-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Poitou',
						image	=> $icons->{fbpoitou},
						items	=> [
							{
								name	=> 'ici Poitou (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbpoitou},
								url	=> 'https://stream.radiofrance.fr/fbpoitou/fbpoitou.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Poitou (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbpoitou},
								url	=> 'http://direct.francebleu.fr/live/fbpoitou-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Provence',
						image	=> $icons->{fbprovence},
						items	=> [
							{
								name	=> 'ici Provence (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbprovence},
								url	=> 'https://stream.radiofrance.fr/fbprovence/fbprovence.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Provence (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbprovence},
								url	=> 'http://direct.francebleu.fr/live/fbprovence-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'RCFM',
						image	=> $icons->{fbrcfm},
						items	=> [
							{
								name	=> 'ici RCFM (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbrcfm},
								url	=> 'https://stream.radiofrance.fr/fbfrequenzamora/fbfrequenzamora.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici RCFM (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbrcfm},
								url	=> 'http://direct.francebleu.fr/live/fbfrequenzamora-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Roussillon',
						image	=> $icons->{fbroussillon},
						items	=> [
							{
								name	=> 'ici Roussillon (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbroussillon},
								url	=> 'https://stream.radiofrance.fr/fbroussillon/fbroussillon.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Roussillon (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbroussillon},
								url	=> 'http://direct.francebleu.fr/live/fbroussillon-midfi.mp3',
								on_select	=> 'play'
							},
						]
						# Non-standard naming 
					},{
						name	=> 'Saint-Étienne Loire',
						image	=> $icons->{fbsaintetienneloire},
						items	=> [
							{
								name	=> 'ici Saint-Étienne Loire (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbsaintetienneloire},
								url	=> 'https://stream.radiofrance.fr/fbstetienne/fbstetienne.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Saint-Étienne Loire (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbsaintetienneloire},
								url	=> 'http://direct.francebleu.fr/live/fbstetienne-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Sud Lorraine',
						image	=> $icons->{fbsudlorraine},
						items	=> [
							{
								name	=> 'ici Sud Lorraine (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbsudlorraine},
								url	=> 'https://stream.radiofrance.fr/fbsudlorraine/fbsudlorraine.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Sud Lorraine (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbsudlorraine},
								url	=> 'http://direct.francebleu.fr/live/fbsudlorraine-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Touraine',
						image	=> $icons->{fbtouraine},
						items	=> [
							{
								name	=> 'ici Touraine (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbtouraine},
								url	=> 'https://stream.radiofrance.fr/fbtouraine/fbtouraine.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Touraine (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbtouraine},
								url	=> 'http://direct.francebleu.fr/live/fbtouraine-midfi.mp3',
								on_select	=> 'play'
							},
						]
					},{
						name	=> 'Vaucluse',
						image	=> $icons->{fbvaucluse},
						items	=> [
							{
								name	=> 'ici Vaucluse (HLS)',
								type	=> 'audio',
								icon	=> $icons->{fbvaucluse},
								url	=> 'https://stream.radiofrance.fr/fbvaucluse/fbvaucluse.m3u8',
								on_select	=> 'play'
							},{
								name	=> 'ici Vaucluse (MP3)',
								type	=> 'audio',
								icon	=> $icons->{fbvaucluse},
								url	=> 'http://direct.francebleu.fr/live/fbvaucluse-midfi.mp3',
								on_select	=> 'play'
							},
						]
					}
					]
			},
			],
		},{
			name => string('PLUGIN_RADIOFRANCE_SCHEDULE'),
			image => 'plugins/RadioFrance/html/images/schedule_MTL_icon_calendar_today.png',
			items => [
				{
					name        => 'France Inter',
					type        => 'link',
					url         => \&getDayMenu,
					image       => $icons->{franceinter},
					passthrough => [
								{
									stationid => 'franceinter'
								}
							],
				},
				{
					name        => 'France Musique',
					type        => 'link',
					url         => \&getDayMenu,
					image       => $icons->{francemusique},
					passthrough => [
								{
									stationid => 'francemusique'
								}
							],
				},
				{
					name        => 'FIP',
					type        => 'link',
					url         => \&getDayMenu,
					image       => $icons->{fipradio},
					passthrough => [
								{
									stationid => 'fipradio'
								}
							],
				},
				{
					name        => 'France Culture',
					type        => 'link',
					url         => \&getDayMenu,
					image       => $icons->{franceculture},
					passthrough => [
								{
									stationid => 'franceculture'
								}
							],
				},
				{
					name        => 'Mouv\'',
					type        => 'link',
					url         => \&getDayMenu,
					image       => $icons->{mouv},
					passthrough => [
								{
									stationid => 'mouv'
								}
							],
				},
				{
					name        => 'franceinfo',
					type        => 'link',
					url         => \&getDayMenu,
					image       => $icons->{franceinfo},
					passthrough => [
								{
									stationid => 'franceinfo'
								}
							],
				},
				{
					name	=> 'ici',
					# until Jan-2025 image	=> 'https://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-bleu.png',
					image	=> 'https://www.radiofrance.fr/client/immutable/assets/francebleu-seosquare.CfwKvmMQ.png',
					items	=> [
					{
						name	=> 'Alsace',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbalsace},
						passthrough	=> [
							{
									stationid => 'fbalsace'
							},
						]
					},{
						name	=> 'Armorique',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbarmorique},
						passthrough	=> [
							{
									stationid => 'fbarmorique'
							},
						]
					},{
						name	=> 'Auxerre',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbauxerre},
						passthrough	=> [
							{
									stationid => 'fbauxerre'
							},
						]
					},{
						name	=> 'Azur',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbazur},
						passthrough	=> [
							{
									stationid => 'fbazur'
							},
						]
					},{
						name	=> 'Béarn',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbbearn},
						passthrough	=> [
							{
									stationid => 'fbbearn'
							},
						]
					},{
						name	=> 'Belfort-Montbéliard',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbbelfort},
						passthrough	=> [
							{
									stationid => 'fbbelfort'
							},
						]
					},{
						name	=> 'Berry',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbberry},
						passthrough	=> [
							{
									stationid => 'fbberry'
							},
						]
					},{
						name	=> 'Besançon',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbbesancon},
						passthrough	=> [
							{
									stationid => 'fbbesancon'
							},
						]
					},{
						name	=> 'Bourgogne',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbbourgogne},
						passthrough	=> [
							{
									stationid => 'fbbourgogne'
							},
						]
					},{
						name	=> 'Breizh Izel',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbbreizhizel},
						passthrough	=> [
							{
									stationid => 'fbbreizhizel'
							},
						]
					},{
						name	=> 'Champagne-Ardenne',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbchampagne},
						passthrough	=> [
							{
									stationid => 'fbchampagne'
							},
						]
					},{
						name	=> 'Cotentin',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbcotentin},
						passthrough	=> [
							{
									stationid => 'fbcotentin'
							},
						]
					},{
						name	=> 'Creuse',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbcreuse},
						passthrough	=> [
							{
									stationid => 'fbcreuse'
							},
						]
					},{
						name	=> 'Drôme Ardèche',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbdromeardeche},
						passthrough	=> [
							{
									stationid => 'fbdromeardeche'
							},
						]
					},{
						name	=> 'Elsass',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbelsass},
						passthrough	=> [
							{
									stationid => 'fbelsass'
							},
						]
					},{
						name	=> 'Gard Lozère',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbgardlozere},
						passthrough	=> [
							{
									stationid => 'fbgardlozere'
							},
						]
					},{
						name	=> 'Gascogne',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbgascogne},
						passthrough	=> [
							{
									stationid => 'fbgascogne'
							},
						]
					},{
						name	=> 'Gironde',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbgironde},
						passthrough	=> [
							{
									stationid => 'fbgironde'
							},
						]
					},{
						name	=> 'Hérault',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbherault},
						passthrough	=> [
							{
									stationid => 'fbherault'
							},
						]
					},{
						name	=> 'Isère',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbisere},
						passthrough	=> [
							{
									stationid => 'fbisere'
							},
						]
					},{
						name	=> 'La Rochelle',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fblarochelle},
						passthrough	=> [
							{
									stationid => 'fblarochelle'
							},
						]
					},{
						name	=> 'Limousin',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fblimousin},
						passthrough	=> [
							{
									stationid => 'fblimousin'
							},
						]
					},{
						name	=> 'Loire Océan',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbloireocean},
						passthrough	=> [
							{
									stationid => 'fbloireocean'
							},
						]
					},{
						name	=> 'Lorraine Nord',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fblorrainenord},
						passthrough	=> [
							{
									stationid => 'fblorrainenord'
							},
						]
					},{
						name	=> 'Maine',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbmaine},
						passthrough	=> [
							{
									stationid => 'fbmaine'
							},
						]
					},{
						name	=> 'Mayenne',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbmayenne},
						passthrough	=> [
							{
									stationid => 'fbmayenne'
							},
						]
					},{
						name	=> 'Nord',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbnord},
						passthrough	=> [
							{
									stationid => 'fbnord'
							},
						]
					},{
						name	=> 'Normandie (Calvados - Orne)',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbbassenormandie},
						passthrough	=> [
							{
									stationid => 'fbbassenormandie'
							},
						]
					},{
						name	=> 'Normandie (Seine-Maritime - Eure)',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbhautenormandie},
						passthrough	=> [
							{
									stationid => 'fbhautenormandie'
							},
						]
					},{
						name	=> 'Occitanie',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbtoulouse},
						passthrough	=> [
							{
									stationid => 'fbtoulouse'
							},
						]
					},{
						name	=> 'Orléans',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fborleans},
						passthrough	=> [
							{
									stationid => 'fborleans'
							},
						]
					},{
						name	=> 'Paris',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbparis},
						passthrough	=> [
							{
									stationid => 'fbparis'
							},
						]
					},{
						name	=> 'Pays Basque',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbpaysbasque},
						passthrough	=> [
							{
									stationid => 'fbpaysbasque'
							},
						]
					},{
						name	=> 'Pays d\'Auvergne',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbpaysdauvergne},
						passthrough	=> [
							{
									stationid => 'fbpaysdauvergne'
							},
						]
					},{
						name	=> 'Pays de Savoie',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbpaysdesavoie},
						passthrough	=> [
							{
									stationid => 'fbpaysdesavoie'
							},
						]
					},{
						name	=> 'Périgord',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbperigord},
						passthrough	=> [
							{
									stationid => 'fbperigord'
							},
						]
					},{
						name	=> 'Picardie',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbpicardie},
						passthrough	=> [
							{
									stationid => 'fbpicardie'
							},
						]
					},{
						name	=> 'Poitou',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbpoitou},
						passthrough	=> [
							{
									stationid => 'fbpoitou'
							},
						]
					},{
						name	=> 'Provence',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbprovence},
						passthrough	=> [
							{
									stationid => 'fbprovence'
							},
						]
					},{
						name	=> 'RCFM',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbrcfm},
						passthrough	=> [
							{
									stationid => 'fbrcfm'
							},
						]
					},{
						name	=> 'Roussillon',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbroussillon},
						passthrough	=> [
							{
									stationid => 'fbroussillon'
							},
						]
					},{
						name	=> 'Saint-Étienne Loire',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbsaintetienneloire},
						passthrough	=> [
							{
									stationid => 'fbsaintetienneloire'
							},
						]
					},{
						name	=> 'Sud Lorraine',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbsudlorraine},
						passthrough	=> [
							{
									stationid => 'fbsudlorraine'
							},
						]
					},{
						name	=> 'Touraine',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbtouraine},
						passthrough	=> [
							{
									stationid => 'fbtouraine'
							},
						]
					},{
						name	=> 'Vaucluse',
						type	=> 'link',
						url	=> \&getDayMenu,
						image	=> $icons->{fbvaucluse},
						passthrough	=> [
							{
									stationid => 'fbvaucluse'
							},
						]
					}
					]
				},
			],
		},
	];

	$callback->( { items => $menu } );

	main::DEBUGLOG && $log->is_debug && $log->debug("--toplevel");
	return;
}


# Get Configuration item (non-blank) value from hierarchy. Return undef if not found or empty
# Priority order (most to least) Station / Provider / plugin Settings / Global Config
sub getConfig {
	my $provider = shift;
	my $station = shift;
	my $settingName = shift;
	
	my $value;

	if ( defined $station && $station ne '' && exists $stationSet->{$station} && exists $stationSet->{$station}->{$settingName} &&
	    (ref $stationSet->{$station}->{$settingName} eq 'ARRAY' || $stationSet->{$station}->{$settingName} ne '' ) ){
		$value = $stationSet->{$station}->{$settingName};
		
		return $value;
	}

	if ( defined $provider && $provider ne '' && exists $broadcasterSet->{$provider} && exists $broadcasterSet->{$provider}->{$settingName} &&
	     (ref $broadcasterSet->{$provider}->{$settingName} eq  'ARRAY' || $broadcasterSet->{$provider}->{$settingName} ne '' ) ){
		$value = $broadcasterSet->{$provider}->{$settingName};
		
		return $value;
	}
	
	$value = $prefs->get($settingName);

	if (defined $value && $value ne ''){
		#main::DEBUGLOG && $log->is_debug && $log->debug("Config value found for $provider station: $station in settings: $settingName: $value");	
		return $value;
	}

	if ( exists $globalSettings->{$settingName} && (ref $globalSettings->{$settingName} eq 'ARRAY' || $globalSettings->{$settingName} ne '' ) ){
		$value = $globalSettings->{$settingName};
		
		return $value;
	}

	#main::DEBUGLOG && $log->is_debug && $log->debug("Config value not found: $settingName for station: $station");	
	return $value;
}

# Return string with leading and trailing whitespace removed
sub _trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

sub _lowercase {
	my $s = shift;
	
	return $s if $s =~ /[a-z]+/;
	
	# uppercase all first characters
	$s =~ s/([\w'\`[:alpha:]äöüéàèçôî]+)/\u\L$1/ig;
		
	# fallback in case locale is wrong 
#	$s =~ tr/äöüàéèçôî/ÄÖÜÀÉÈÇÔÎ/;

	$s =~ s/^\s+//;
	$s =~ s/[\:\s]+$//;
	
	return $s;
}

1;

__END__
