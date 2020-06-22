# Slimerver/LMS PlugIn to get Metadata from Radio France stations
# Copyright (C) 2017, 2018, 2019 Paul Webster
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

package Plugins::RadioFrance::Plugin;

use utf8;
use strict;
use warnings;

use vars qw($VERSION);
use HTML::Entities;
use Digest::SHA1;
use HTTP::Request;

use Date::Parse;
use File::Spec::Functions qw(:ALL);

use base qw(Slim::Plugin::OPMLBased);


use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::RadioFrance::Settings;

# use JSON;		# JSON.pm Not installed on all LMS implementations so use LMS-friendly one below
use JSON::XS::VersionOneAndTwo;
use Encode;
use Data::Dumper
$Data::Dumper::Sortkeys = 1;

use constant false => 0;
use constant true  => 1;

my $pluginName = 'radiofrance';

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.'.$pluginName,
	'description'  => 'PLUGIN_RADIOFRANCE',
});

my $prefs = preferences('plugin.'.$pluginName);

use constant cacheTTL => 20;
use constant maxSongLth => 900;		# Assumed maximum song length in seconds - if appears longer then no duration shown
use constant maxShowLth => 3600;	# Assumed maximum programme length in seconds - if appears longer then no duration shown
					# because might be a problem with the data
					# Having no duration should mean earlier call back to try again
					
					# Where images of different sizes are available (and can be determined) from the source then
					# try to keep them to no more than indicated - applies to cover art and programme logo
use constant maxImgWidth => 340;
use constant maxImgHeight => 340;
					
# If no image provided in return then try to create one from 'visual' or 'visualbanner'
my $imageapiprefix = 'https://api.radiofrance.fr/v1/services/embed/image/';
my $imageapisuffix = '?preset=400x400';

# GraphQL queries for data from Radio France - insert the numeric station id between prefix1 and prefix2
my $type3prefix1fip = 'https://www.fip.fr/latest/api/graphql?operationName=NowList&variables=%7B%22bannerPreset%22%3A%22266x266%22%2C%22stationIds%22%3A%5B';
my $type3prefix2fip = '%5D%7D';
my $type3suffix    = '&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22a6f39630b68ceb8e56340a4478e099d05c9f5fc1959eaccdfb81e2ce295d82a5%22%7D%7D';
my $type3suffixfip = '&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22151ca055b816d28507dae07f9c036c02031ed54e18defc3d16feee2551e9a731%22%7D%7D';

# URL for remote web site that is polled to get the information about what is playing
#
my $progListPerStation = true;	# Flag if programme list fetches are per station or for all stations (optimises fetches)

my $trackInfoPrefix = '';
my $trackInfoSuffix = '';

my $progInfoPrefix = '';
my $progInfoSuffix = '';

my $progDetailsURL = '';

my $stationSet = { # Take extra care if pasting in from external spreadsheet ... station name with single quote, TuneIn ids, longer match1 for duplicate
	fipradio => { fullname => 'FIP', stationid => '7', region => '', tuneinid => 's15200', notexcludable => true, match1 => '', match2 => 'fip' },
	fipbordeaux => { fullname => 'FIP Bordeaux', stationid => '7', region => '', tuneinid => 's50706', notexcludable => true, match1 => 'fipbordeaux', match2 => '' },
	fipnantes => { fullname => 'FIP Nantes', stationid => '7', region => '', tuneinid => 's50770', notexcludable => true, match1 => 'fipnantes', match2 => '' },
	fipstrasbourg => { fullname => 'FIP Strasbourg', stationid => '7', region => '', tuneinid => 's111944', notexcludable => true, match1 => 'fipstrasbourg', match2 => '' },
	fiprock => { fullname => 'FIP Rock', stationid => '64', region => '', tuneinid => 's262528', notexcludable => true, match1 => 'fip-webradio1.', match2 => 'fiprock' },
	fipjazz => { fullname => 'FIP Jazz', stationid => '65', region => '', tuneinid => 's262533', notexcludable => true, match1 => 'fip-webradio2.', match2 => 'fipjazz' },
	fipgroove => { fullname => 'FIP Groove', stationid => '66', region => '', tuneinid => 's262537', notexcludable => true, match1 => 'fip-webradio3.', match2 => 'fipgroove' },
	fipmonde => { fullname => 'FIP Monde', stationid => '69', region => '', tuneinid => 's262538', notexcludable => true, match1 => 'fip-webradio4.', match2 => 'fipworld' },
	fipnouveau => { fullname => 'Tout nouveau, tout Fip', stationid => '70', region => '', tuneinid => 's262540', notexcludable => true, match1 => 'fip-webradio5.', match2 => 'fipnouveautes' },
	fipreggae => { fullname => 'FIP Reggae', stationid => '71', region => '', tuneinid => 's293090', notexcludable => true, match1 => 'fip-webradio6.', match2 => 'fipreggae' },
	fipelectro => { fullname => 'FIP Electro', stationid => '74', region => '', tuneinid => 's293089', notexcludable => true, match1 => 'fip-webradio8.', match2 => 'fipelectro' },
	fipmetal => { fullname => 'FIP L\'été Metal', stationid => '77', region => '', tuneinid => 's308366', notexcludable => true, match1 => 'fip-webradio7.', match2 => 'fipmetal' },
	fippop => { fullname => 'FIP Pop', stationid => '78', region => '', tuneinid => '', notexcludable => true, match1 => 'fip-webradio8.', match2 => 'fippop' },

	fmclassiqueeasy => { fullname => 'France Musique Classique Easy', stationid => '401', region => '', tuneinid => 's283174', notexcludable => true, match1 => 'francemusiqueeasyclassique', match2 => '' },
	fmclassiqueplus => { fullname => 'France Musique Classique Plus', stationid => '402', region => '', tuneinid => 's283175', notexcludable => true, match1 => 'francemusiqueclassiqueplus', match2 => '' },
	fmconcertsradiofrance => { fullname => 'France Musique Concerts', stationid => '403', region => '', tuneinid => 's283176', notexcludable => true, match1 => 'francemusiqueconcertsradiofrance', match2 => '' },
	fmlajazz => { fullname => 'France Musique La Jazz', stationid => '405', region => '', tuneinid => 's283178', notexcludable => true, match1 => 'francemusiquelajazz', match2 => '' },
	fmlacontemporaine => { fullname => 'France Musique La Contemporaine', stationid => '406', region => '', tuneinid => 's283179', notexcludable => true, match1 => 'francemusiquelacontemporaine', match2 => '' },
	fmocoramonde => { fullname => 'France Musique Ocora Monde', stationid => '404', region => '', tuneinid => 's283177', notexcludable => true, match1 => 'francemusiqueocoramonde', match2 => '' },
	#fmevenementielle => { fullname => 'France Musique Evenementielle', stationid => '407', region => '', tuneinid => 's285660&|id=s306575', notexcludable => true, match1 => 'francemusiquelevenementielle', match2 => '' }, # Special case ... 2 TuneIn Id
	fmlabo => { fullname => 'France Musique La B.O. de Films', stationid => '407', region => '', tuneinid => 's306575', notexcludable => true, match1 => 'francemusiquelabo', match2 => '' }, 

	mouv => { fullname => 'Mouv\'', stationid => '6', region => '', tuneinid => 's6597', notexcludable => true, match1 => 'mouv', match2 => '' },
	mouvxtra => { fullname => 'Mouv\' Xtra', stationid => '75', region => '', tuneinid => '', notexcludable => true, match1 => 'mouvxtra', match2 => '' },
	mouvclassics => { fullname => 'Mouv\' Classics', stationid => '601', region => '', tuneinid => 's307696', notexcludable => true, match1 => 'mouvclassics', match2 => '' },
	mouvdancehall => { fullname => 'Mouv\' Dancehall', stationid => '602', region => '', tuneinid => 's307697', notexcludable => true, match1 => 'mouvdancehall', match2 => '' },
	mouvrnb => { fullname => 'Mouv\' R\'N\'B', stationid => '603', region => '', tuneinid => 's307695', notexcludable => true, match1 => 'mouvrnb', match2 => '' },
	mouvrapus => { fullname => 'Mouv\' RAP US', stationid => '604', region => '', tuneinid => 's307694', notexcludable => true, match1 => 'mouvrapus', match2 => '' },
	mouvrapfr => { fullname => 'Mouv\' RAP Français', stationid => '605', region => '', tuneinid => 's307693', notexcludable => true, match1 => 'mouvrapfr', match2 => '' },
	mouvkidsnfamily => { fullname => 'Mouv\' Kids\'n Family', stationid => '606', region => '', tuneinid => '', notexcludable => true, match1 => 'mouvkidsnfamily', match2 => '' },
	mouv100mix => { fullname => 'Mouv\' 100\% Mix', stationid => '75', region => '', tuneinid => 's244069', notexcludable => true, match1 => 'mouv100p100mix', match2 => '' },

	franceinter => { fullname => 'France Inter', stationid => '1', region => '', tuneinid => 's24875', notexcludable => false, match1 => 'franceinter', match2 => '' },
	franceinfo => { fullname => 'France Info', stationid => '2', region => '', tuneinid => 's9948', notexcludable => false, match1 => 'franceinfo', match2 => '' },
	francemusique => { fullname => 'France Musique', stationid => '4', region => '', tuneinid => 's15198', notexcludable => false, match1 => 'francemusique', match2 => '' },
	franceculture => { fullname => 'France Culture', stationid => '5', region => '', tuneinid => 's2442', notexcludable => false, match1 => 'franceculture', match2 => '' },

	fbalsace => { fullname => 'France Bleu Alsace', stationid => '12', region => '', tuneinid => 's2992', notexcludable => false, match1 => 'fbalsace', match2 => '', scheduleurl => '' },
	fbarmorique => { fullname => 'France Bleu Armorique', stationid => '13', region => '', tuneinid => 's25492', notexcludable => false, match1 => 'fbarmorique', match2 => '', scheduleurl => '' },
	fbauxerre => { fullname => 'France Bleu Auxerre', stationid => '14', region => '', tuneinid => 's47473', notexcludable => false, match1 => 'fbauxerre', match2 => '', scheduleurl => '' },
	fbazur => { fullname => 'France Bleu Azur', stationid => '49', region => '', tuneinid => 's45035', notexcludable => false, match1 => 'fbazur', match2 => '', scheduleurl => '' },
	fbbearn => { fullname => 'France Bleu Béarn', stationid => '15', region => '', tuneinid => 's48291', notexcludable => false, match1 => 'fbbearn', match2 => '', scheduleurl => '' },
	fbbelfort => { fullname => 'France Bleu Belfort-Montbéliard', stationid => '16', region => '', tuneinid => 's25493', notexcludable => false, match1 => 'fbbelfort', match2 => '', scheduleurl => '' },
	fbberry => { fullname => 'France Bleu Berry', stationid => '17', region => '', tuneinid => 's48650', notexcludable => false, match1 => 'fbberry', match2 => '', scheduleurl => '' },
	fbbesancon => { fullname => 'France Bleu Besançon', stationid => '18', region => '', tuneinid => 's48652', notexcludable => false, match1 => 'fbbesancon', match2 => '', scheduleurl => '' },
	fbbourgogne => { fullname => 'France Bleu Bourgogne', stationid => '19', region => '', tuneinid => 's36092', notexcludable => false, match1 => 'fbbourgogne', match2 => '', scheduleurl => '' },
	fbbreizhizel => { fullname => 'France Bleu Breizh Izel', stationid => '20', region => '', tuneinid => 's25494', notexcludable => false, match1 => 'fbbreizizel', match2 => '', scheduleurl => '' },
	fbchampagne => { fullname => 'France Bleu Champagne-Ardenne', stationid => '21', region => '', tuneinid => 's47472', notexcludable => false, match1 => 'fbchampagne', match2 => '', scheduleurl => '' },
	fbcotentin => { fullname => 'France Bleu Cotentin', stationid => '37', region => '', tuneinid => 's36093', notexcludable => false, match1 => 'fbcotentin', match2 => '', scheduleurl => '' },
	fbcreuse => { fullname => 'France Bleu Creuse', stationid => '23', region => '', tuneinid => 's2997', notexcludable => false, match1 => 'fbcreuse', match2 => '', scheduleurl => '' },
	fbdromeardeche => { fullname => 'France Bleu Drôme Ardèche', stationid => '24', region => '', tuneinid => 's48657', notexcludable => false, match1 => 'fbdromeardeche', match2 => '', scheduleurl => '' },
	fbelsass => { fullname => 'France Bleu Elsass', stationid => '90', region => '', tuneinid => 's74418', notexcludable => false, match1 => 'fbelsass', match2 => '', scheduleurl => '' },
	fbgardlozere => { fullname => 'France Bleu Gard Lozère', stationid => '25', region => '', tuneinid => 's36094', notexcludable => false, match1 => 'fbgardlozere', match2 => '', scheduleurl => '' },
	fbgascogne => { fullname => 'France Bleu Gascogne', stationid => '26', region => '', tuneinid => 's47470', notexcludable => false, match1 => 'fbgascogne', match2 => '', scheduleurl => '' },
	fbgironde => { fullname => 'France Bleu Gironde', stationid => '27', region => '', tuneinid => 's48659', notexcludable => false, match1 => 'fbgironde', match2 => '', scheduleurl => '' },
	fbherault => { fullname => 'France Bleu Hérault', stationid => '28', region => '', tuneinid => 's48665', notexcludable => false, match1 => 'fbherault', match2 => '', scheduleurl => '' },
	fbisere => { fullname => 'France Bleu Isère', stationid => '29', region => '', tuneinid => 's20328', notexcludable => false, match1 => 'fbisere', match2 => '', scheduleurl => '' },
	fblarochelle => { fullname => 'France Bleu La Rochelle', stationid => '30', region => '', tuneinid => 's48669', notexcludable => false, match1 => 'fblarochelle', match2 => '', scheduleurl => '' },  #Possible alternate for schedule https://www.francebleu.fr/grid/la-rochelle/${unixtime}
	fblimousin => { fullname => 'France Bleu Limousin', stationid => '31', region => '', tuneinid => 's48670', notexcludable => false, match1 => 'fblimousin', match2 => '', scheduleurl => '' },
	fbloireocean => { fullname => 'France Bleu Loire Océan', stationid => '32', region => '', tuneinid => 's36096', notexcludable => false, match1 => 'fbloireocean', match2 => '', scheduleurl => '' },
	fblorrainenord => { fullname => 'France Bleu Lorraine Nord', stationid => '50', region => '', tuneinid => 's48672', notexcludable => false, match1 => 'fblorrainenord', match2 => '', scheduleurl => '' },
	fbmaine => { fullname => 'France Bleu Maine', stationid => '91', region => '', tuneinid => 's127941', notexcludable => false, match1 => 'fbmaine', match2 => '', scheduleurl => '' },
	fbmayenne => { fullname => 'France Bleu Mayenne', stationid => '34', region => '', tuneinid => 's48673', notexcludable => false, match1 => 'fbmayenne', match2 => '', scheduleurl => '' },
	fbnord => { fullname => 'France Bleu Nord', stationid => '36', region => '', tuneinid => 's44237', notexcludable => false, match1 => 'fbnord', match2 => '', scheduleurl => '' },
	fbbassenormandie => { fullname => 'France Bleu Normandie (Calvados - Orne)', stationid => '22', region => '', tuneinid => 's48290', notexcludable => false, match1 => 'fbbassenormandie', match2 => '', scheduleurl => '' },
	fbhautenormandie => { fullname => 'France Bleu Normandie (Seine-Maritime - Eure)', stationid => '38', region => '', tuneinid => 's222667', notexcludable => false, match1 => 'fbhautenormandie', match2 => '', scheduleurl => '' },
	fbtoulouse => { fullname => 'France Bleu Occitanie', stationid => '92', region => '', tuneinid => 's50669', notexcludable => false, match1 => 'fbtoulouse', match2 => '', scheduleurl => '' },
	fborleans => { fullname => 'France Bleu Orléans', stationid => '39', region => '', tuneinid => 's1335', notexcludable => false, match1 => 'fborleans', match2 => '', scheduleurl => '' },
	fbparis => { fullname => 'France Bleu Paris', stationid => '68', region => '', tuneinid => 's52972', notexcludable => false, match1 => 'fb1071', match2 => '', scheduleurl => '' },
	fbpaysbasque => { fullname => 'France Bleu Pays Basque', stationid => '41', region => '', tuneinid => 's48682', notexcludable => false, match1 => 'fbpaysbasque', match2 => '', scheduleurl => '' },
	fbpaysdauvergne => { fullname => 'France Bleu Pays d&#039;Auvergne', stationid => '40', region => '', tuneinid => 's48683', notexcludable => false, match1 => 'fbpaysdauvergne', match2 => '', scheduleurl => '' },
	fbpaysdesavoie => { fullname => 'France Bleu Pays de Savoie', stationid => '42', region => '', tuneinid => 's45038', notexcludable => false, match1 => 'fbpaysdesavoie', match2 => '', scheduleurl => '' },
	fbperigord => { fullname => 'France Bleu Périgord', stationid => '43', region => '', tuneinid => 's2481', notexcludable => false, match1 => 'fbperigord', match2 => '', scheduleurl => '' },
	fbpicardie => { fullname => 'France Bleu Picardie', stationid => '44', region => '', tuneinid => 's25497', notexcludable => false, match1 => 'fbpicardie', match2 => '', scheduleurl => '' },
	fbpoitou => { fullname => 'France Bleu Poitou', stationid => '54', region => '', tuneinid => 's47471', notexcludable => false, match1 => 'fbpoitou', match2 => '', scheduleurl => '' },
	fbprovence => { fullname => 'France Bleu Provence', stationid => '45', region => '', tuneinid => 's1429', notexcludable => false, match1 => 'fbprovence', match2 => '', scheduleurl => '' },
	fbrcfm => { fullname => 'France Bleu RCFM', stationid => '11', region => '', tuneinid => 's48656', notexcludable => false, match1 => 'fbfrequenzamora', match2 => '', scheduleurl => '' },
	fbroussillon => { fullname => 'France Bleu Roussillon', stationid => '46', region => '', tuneinid => 's48689', notexcludable => false, match1 => 'fbroussillon', match2 => '', scheduleurl => '' },
	fbsaintetienneloire => { fullname => 'France Bleu Saint-Étienne Loire', stationid => '93', region => '', tuneinid => 's212244', notexcludable => false, match1 => 'fbstetienne', match2 => '', scheduleurl => '' },
	fbsudlorraine => { fullname => 'France Bleu Sud Lorraine', stationid => '33', region => '', tuneinid => 's45039', notexcludable => false, match1 => 'fbsudlorraine', match2 => '', scheduleurl => '' },
	fbtouraine => { fullname => 'France Bleu Touraine', stationid => '47', region => '', tuneinid => 's48694', notexcludable => false, match1 => 'fbtouraine', match2 => '', scheduleurl => '' },
	fbvaucluse => { fullname => 'France Bleu Vaucluse', stationid => '48', region => '', tuneinid => 's47474', notexcludable => false, match1 => 'fbvaucluse', match2 => '', scheduleurl => '' },

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
# However, having both versions can lead to oddities e.g. artist names represented slightly differently when multiple so# for now leave the livemeta/pull as
# primary and do not use _alt but left in the code to make it fairly easy to switch later if livemeta/pull is retired

my $urls = {
	radiofranceprogdata => '', # 
	radiofranceprogdata_alt => '',
	radiofrancebroadcasterdata => '',
	
	# Note - loop below adds one hash for each station
# finished 1521553005 - 2018-03-20 13:36:45	fipradio_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipradio => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipradio_alt => $type3prefix1fip.'7'.$type3prefix2fip.$type3suffixfip,
# finished 1521553005 - 2018-03-20 13:36:45	fipbordeaux_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipbordeaux => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipbordeaux_alt => $type3prefix1fip.'7'.$type3prefix2fip.$type3suffixfip,
# finished 1521553005 - 2018-03-20 13:36:45	fipnantes_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipnantes => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipnantes_alt => $type3prefix1fip.'7'.$type3prefix2fip.$type3suffixfip,
# finished 1521553005 - 2018-03-20 13:36:45	fipstrasbourg_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipstrasbourg => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipstrasbourg_alt => $type3prefix1fip.'7'.$type3prefix2fip.$type3suffixfip,
# finished 1507650288 - 2017-10-10 16:44:48	fiprock_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_1/si_titre_antenne/FIP_player_current.json',
	fiprock => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fiprock_alt => $type3prefix1fip.'64'.$type3prefix2fip.$type3suffixfip,
# finished 1507650914 - 2017-10-10 16:55:14	fipjazz_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_2/si_titre_antenne/FIP_player_current.json',
	fipjazz => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipjazz_alt => $type3prefix1fip.'65'.$type3prefix2fip.$type3suffixfip,
# finished 1507650885 - 2017-10-10 16:54:45	fipgroove_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_3/si_titre_antenne/FIP_player_current.json',
	fipgroove => 'https://api.radiofrance.fr/livemeta//pull/${stationid}',
	#fipgroove_alt => $type3prefix1fip.'66'.$type3prefix2fip.$type3suffixfip,
# finished 1507650800 - 2017-10-10 16:53:20	fipmonde_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_4/si_titre_antenne/FIP_player_current.json',
	fipmonde => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipmonde_alt => $type3prefix1fip.'69'.$type3prefix2fip.$type3suffixfip,
# finished 1507650797 - 2017-10-10 16:53:17	fipnouveau_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_5/si_titre_antenne/FIP_player_current.json',
	fipnouveau => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipnouveau_alt => $type3prefix1fip.'70'.$type3prefix2fip.$type3suffixfip,
# finished 1507650800 - 2017-10-10 16:53:20	fipevenement_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_6/si_titre_antenne/FIP_player_current.json',
# FIP Evenement became FIP Autour Du Reggae
	fipreggae => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipreggae_alt => $type3prefix1fip.'71'.$type3prefix2fip.$type3suffixfip,
	fipelectro => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipelectro_alt => $type3prefix1fip.'74'.$type3prefix2fip.$type3suffixfip,
	fipmetal => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fipmetal_alt => $type3prefix1fip.'77'.$type3prefix2fip.$type3suffixfip,
	
	fmclassiqueeasy => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmclassiqueeasy_alt => $type3prefix1fip.'401'.$type3prefix2fip.$type3suffixfip,
	fmclassiqueplus => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmclassiqueplus_alt => $type3prefix1fip.'402'.$type3prefix2fip.$type3suffixfip,
	fmconcertsradiofrance => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmconcertsradiofrance_alt => $type3prefix1fip.'403'.$type3prefix2fip.$type3suffixfip,
	fmlajazz => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmlajazz_alt => $type3prefix1fip.'405'.$type3prefix2fip.$type3suffixfip,
	fmlacontemporaine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmlacontemporaine_alt => $type3prefix1fip.'406'.$type3prefix2fip.$type3suffixfip,
	fmocoramonde => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmocoramonde_alt => $type3prefix1fip.'404'.$type3prefix2fip.$type3suffixfip,
	#fmevenementielle => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fmlabo => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#fmlabo_alt => $type3prefix1fip.'407'.$type3prefix2fip.$type3suffixfip,
	
	mouv => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#mouv_alt => $type3prefix1fip.'6'.$type3prefix2fip.$type3suffixfip,
	mouvxtra => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	#mouvxtra_alt => $type3prefix1fip.'75'.$type3prefix2fip.$type3suffixfip,
	mouvclassics => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A601%7D&'.$type3suffix,
	#mouvclassics_alt => $type3prefix1fip.'601'.$type3prefix2fip.$type3suffixfip,
	mouvdancehall => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A602%7D&'.$type3suffix,
	#mouvdancehall_alt => $type3prefix1fip.'602'.$type3prefix2fip.$type3suffixfip,
	mouvrnb => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A603%7D&'.$type3suffix,
	#mouvrnb_alt => $type3prefix1fip.'603'.$type3prefix2fip.$type3suffixfip,
	mouvrapus => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A604%7D&'.$type3suffix,
	#mouvrapus_alt => $type3prefix1fip.'604'.$type3prefix2fip.$type3suffixfip,
	mouvrapfr => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A605%7D&'.$type3suffix,
	#mouvrapfr_alt => $type3prefix1fip.'605'.$type3prefix2fip.$type3suffixfip,
	mouv100mix => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A75%7D&'.$type3suffix,
	#mouv100mix_alt => $type3prefix1fip.'75'.$type3prefix2fip.$type3suffixfip,
	
	franceinter => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	franceinfo => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	francemusique => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	franceculture => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	
	# Limited song data from France Bleu stations
	fbalsace => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbarmorique => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbauxerre => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbazur => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbearn => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbelfort => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbberry => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbesancon => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbourgogne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbreizhizel => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbchampagne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbcotentin => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbcreuse => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbdromeardeche => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbelsass => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbgardlozere => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbgascogne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbgironde => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbherault => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbisere => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fblarochelle => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fblimousin => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbloireocean => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fblorrainenord => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbmaine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbmayenne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbnord => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbbassenormandie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbhautenormandie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbtoulouse => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fborleans => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbparis => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpaysbasque => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpaysdauvergne => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpaysdesavoie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbperigord => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpicardie => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbpoitou => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbprovence => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbrcfm => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbroussillon => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbsaintetienneloire => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbsudlorraine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbtouraine => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
	fbvaucluse => 'https://api.radiofrance.fr/livemeta/pull/${stationid}',
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
	fipradio => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fipbordeaux => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fipnantes => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fipstrasbourg => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/fip.png',
	fiprock => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg',
	fipjazz => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/840a4431-0db0-4a94-aa28-53f8de011ab6/200x200_fip-jazz-01.jpg',
	fipgroove => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/3673673e-30f7-4caf-92c6-4161485d284d/200x200_fip-groove_ok.jpg',
	fipmonde => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/9a1d42c5-8a36-4253-bfae-bdbfb85cbe14/200x200_fip-monde_ok.jpg',
	fipnouveau => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/e061141c-f6b4-4502-ba43-f6ec693a049b/200x200_fip-nouveau_ok.jpg',
	fipreggae => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/15a58f25-86a5-4b1a-955e-5035d9397da3/200x200_fip-reggae_ok.jpg',
	fipelectro => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/29044099-6469-4f2f-845c-54e607179806/200x200_fip-electro-ok.jpg',
	fipmetal => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5ce2c85-3c8a-4732-8bd7-b26ef5204147/200x200_fip-ete-metal_ok.jpg',
	fippop => 'https://cdn.radiofrance.fr/s3/cruiser-production/2020/06/538d3800-c610-4b76-9cb1-37142abd755b/801x410_logopop.jpg',
	
	fmclassiqueeasy => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/aca436ad-7f99-4765-9404-1b04bf216daf/fmwebradiosnormaleasy.jpg',
	fmclassiqueplus => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/b8213b77-465c-487e-b5b6-07ce8e2862df/fmwebradiosnormalplus.jpg',
	fmconcertsradiofrance => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/72f1a384-5b04-4b98-b511-ac07b35c7daf/fmwebradiosnormalconcerts.jpg',
	fmlajazz => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/a2d34823-36a1-4fce-b3fa-f0579e056552/fmwebradiosnormaljazz.jpg',
	fmlacontemporaine => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/92f9a1f4-5525-4b2a-af13-213ff3b0c0a6/fmwebradiosnormalcontemp.jpg',
	fmocoramonde => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/22b8b3d6-e848-4090-8b24-141c25225861/fmwebradiosnormalocora.jpg',
	#fmevenementielle => 'https://cdn.radiofrance.fr/s3/cruiser-production/2017/06/d2ac7a26-843d-4f0c-a497-8ddf6f3b2f0f/200x200_fmwebbotout.jpg',
	fmlabo => 'https://cdn.radiofrance.fr/s3/cruiser-production/2017/06/d2ac7a26-843d-4f0c-a497-8ddf6f3b2f0f/200x200_fmwebbotout.jpg',
	
	mouv => 'https://www.radiofrance.fr/sites/default/files/styles/format_16_9/public/2019-08/logo_mouv_bloc_c.png.jpeg',
	mouvxtra => 'http://www.mouv.fr/sites/all/modules/rf/rf_lecteur_commun/lecteur_rf/img/logo_mouv_xtra.png',
	mouvclassics => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/bb8da8da-f679-405f-8810-b4a172f6a32d/300x300_mouv-classic_02.jpg',
	mouvdancehall => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/9d04e918-c907-4627-a332-1071bdc2366e/300x300_dancehall.jpg',
	mouvrnb => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/f3bf764e-637c-48c0-b152-1a258726710f/300x300_rnb.jpg',
	mouvrapus => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/54f3a745-fcf5-4f62-885a-a014cdd50a62/300x300_rapus.jpg',
	mouvrapfr => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/3c4dc967-ed2c-4ce5-a998-9437a64e05d5/300x300_rapfr.jpg',
	mouv100mix => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/689453b1-de6c-4c9e-9ebd-de70d0220e69/300x300_mouv-100mix-final.jpg',
	mouvkidsnfamily => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/08/20b36ec0-fd19-4d92-b393-7977277e1452/300x300_mouv_webradio_kids_n_family.jpg',
	
	franceinter => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-inter.png',
	franceinfo => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-info.png',
	francemusique => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-musique.png',
	franceculture => 'http://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-culture.png',
	
	fbalsace => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_alsace.jpg',
	fbarmorique => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_armorique.jpg',
	fbauxerre => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_auxerre.jpg',
	fbazur => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_azur.jpg',
	fbbearn => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_bearn.jpg',
	fbbelfort => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_belfort-montbeliard.jpg',
	fbberry => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_berry.jpg',
	fbbesancon => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_besancon.jpg',
	fbbourgogne => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_bourgogne.jpg',
	fbbreizhizel => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_breizh-izel.jpg',
	fbchampagne => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_champagne-ardenne.jpg',
	fbcotentin => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_cotentin.jpg',
	fbcreuse => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_creuse.jpg',
	fbdromeardeche => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_drome-ardeche.jpg',
	fbelsass => 'https://mediateur.radiofrance.fr/wp-content/themes/radiofrance/img/france-bleu.png',	# Wrong logo
	fbgardlozere => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_gard-lozere.jpg',
	fbgascogne => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_gascogne.jpg',
	fbgironde => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_gironde.jpg',
	fbherault => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_herault.jpg',
	fbisere => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_isere.jpg',
	fblarochelle => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_la-rochelle.jpg',
	fblimousin => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_limousin.jpg',
	fbloireocean => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_loire-ocean.jpg',
	fblorrainenord => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_lorraine-nord.jpg',
	fbmaine => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_maine.jpg',
	fbmayenne => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_mayenne.jpg',
	fbnord => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_nord.jpg',
	fbbassenormandie => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_normandie.jpg',	# Wrong logo
	fbhautenormandie => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_normandie.jpg',	# Wrong logo
	fbtoulouse => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_toulouse.jpg',
	fborleans => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_orleans.jpg',
	fbparis => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_paris.png',
	fbpaysbasque => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_pays-basque.jpg',
	fbpaysdauvergne => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_auvergne.jpg',
	fbpaysdesavoie => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_savoie.jpg',
	fbperigord => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_perigord.jpg',
	fbpicardie => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_picardie.jpg',
	fbpoitou => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_poitou.jpg',
	fbprovence => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_provence.jpg',
	fbrcfm => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_rcfm.jpg',
	fbroussillon => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_roussillon.jpg',
	fbsaintetienneloire => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_saint-etienne-loire.jpg',
	fbsudlorraine => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_sud-lorraine.jpg',
	fbtouraine => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_touraine.jpg',
	fbvaucluse => 'https://www.francebleu.fr/img/station/logo/logo_francebleu_vaucluse.jpg',
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
	fipradio => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipbordeaux => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipnantes => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipstrasbourg => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fiprock => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipjazz => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipgroove => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipmonde => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipnouveau => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipreggae => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipelectro => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fipmetal => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	fippop => '(fond_titres_diffuses_degrade.png|direct_default_cover_medium.png)',
	mouv => '(image_default_player.jpg)',
	mouvxtra => '(image_default_player.jpg)',
	mouvclassics => '(image_default_player.jpg)',
	mouvdancehall => '(image_default_player.jpg)',
	mouvrnb => '(image_default_player.jpg)',
	mouvrapus => '(image_default_player.jpg)',
	mouvrapfr => '(image_default_player.jpg)',
	mouv100mix => '(image_default_player.jpg)',
};

foreach my $metakey (keys(%$stationSet)){
	# Inialise the iconsIgnoreRegex table
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising iconsIgnoreRegex - $metakey");
	if ( not exists $iconsIgnoreRegex->{$metakey} ){
		# Customise this if necessary per plugin
		$iconsIgnoreRegex->{$metakey} = '(dummy)';
	}
}


# Uses match group 1 from regex call to try to find station
my %stationMatches = (
);

my $thisMatchStr = '';
foreach my $metakey (keys(%$stationSet)){
	# Inialise the stationMatches table - do not replace items that are already present (to allow override)
	# main::DEBUGLOG && $log->is_debug && $log->debug("Initialising stationMatches - $metakey");
	if ( exists $stationSet->{$metakey}->{'tuneinid'} && $stationSet->{$metakey}->{'tuneinid'} ne ''){
		# TuneIn id given so add it in (if not already there)
		$thisMatchStr = 'id='.$stationSet->{$metakey}->{'tuneinid'}.'&';
		
		if ( not exists $stationMatches{$thisMatchStr} ){
			# main::DEBUGLOG && $log->is_debug && $log->debug("Adding to stationMatches - $thisMatchStr - $metakey");
			$stationMatches{$thisMatchStr} = $metakey;
		}
	}
	
	if ( exists $stationSet->{$metakey}->{'match1'} && $stationSet->{$metakey}->{'match1'} ne ''){
		# match1 given so add it in (if not already there)
		$thisMatchStr = $stationSet->{$metakey}->{'match1'};
		
		if ( not exists $stationMatches{lc($thisMatchStr)} ){
			# main::DEBUGLOG && $log->is_debug && $log->debug("Adding to stationMatches - $thisMatchStr - $metakey");
			$stationMatches{lc($thisMatchStr)} = $metakey;
		}
	}
	
	if ( exists $stationSet->{$metakey}->{'match2'} && $stationSet->{$metakey}->{'match2'} ne ''){
		# match2 given so add it in (if not already there)
		$thisMatchStr = $stationSet->{$metakey}->{'match2'};
		
		if ( not exists $stationMatches{lc($thisMatchStr)} ){
			# main::DEBUGLOG && $log->is_debug && $log->debug("Adding to stationMatches - $thisMatchStr - $metakey");
			$stationMatches{lc($thisMatchStr)} = $metakey;
		}
	}
}

my $dumped;
	
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

my @coverFieldsArr = ( "cover", "visual", "coverUuid", "visualBanner" );


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
			feed   => Slim::Utils::Misc::fileURLFromPath($file),
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

	foreach my $fieldName ( @coverFieldsArr ) {
		# Loop through the list of field names and take first (if any) match
		if ( exists $playinginfo->{$fieldName} && defined($playinginfo->{$fieldName}) && $playinginfo->{$fieldName} ne '' ){
			$thisartwork = $playinginfo->{$fieldName};
			last;
		}
	}

	# Now check to see if there are any size issues and replace if possible
	# Note - this uses attributes found in ABC Australia data so would need changing for other sources
	if ( exists $playinginfo->{width} && defined($playinginfo->{width}) &&
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

	if (($thisartwork ne '' && ($thisartwork !~ /$iconsIgnoreRegex/ || ($info ne '' && $thisartwork eq $info->{icon}))) &&
	     ($thisartwork =~ /^https?:/i) || $thisartwork =~ /^.*-.*-.*-.*-/){
	     # There is something, it is not excluded, it is not the station logo and (it appears to be a URL or an id)
	     # example id "visual": "38fab9df-91cc-4e50-adc4-eb3a9f2a017a",
		if ($thisartwork =~ /^.*-.*-.*-.*-/ && $thisartwork !~ /^https?:/i){
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - image id $thisartwork");
			$thisartwork = $imageapiprefix.$thisartwork.$imageapisuffix;
		}
		
	} else {
		# Icon not present or matches one to be ignored
		# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$playinginfo->{'visual'});
	}
	
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
				$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
				$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
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
					$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
					$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
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
		# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - IsPlaying=".$client->isPlaying." getmeta called with URL $url");

		my $hiResTime = getLocalAdjustedTime;
		
		# don't query the remote meta data every time we're called
		if ( $perStation ) { $whenFetchedKey = $station; }

		if ( not exists $programmeMeta->{'whenfetched'}->{$whenFetchedKey} ){
			$programmeMeta->{'whenfetched'}->{$whenFetchedKey} = '';
		}
		
		
		if ( $client->isPlaying && ($programmeMeta->{'whenfetched'}->{$whenFetchedKey} eq '' || $programmeMeta->{'whenfetched'}->{$whenFetchedKey} <= $hiResTime - 60)) {
			
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
				$sourceUrl =~ s/\$\{region\}/$stationSet->{$station}->{'region'}/g;
				$sourceUrl =~ s/\$\{progid\}/$calculatedPlaying->{$station}->{'progid'}/g;
				$sourceUrl =~ s/\$\{unixtime\}/$hiResTime/g;
			}
			
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching programme data from $sourceUrl");
			$http->get($sourceUrl);
			
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
			
			$dataType = '1';
			
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
					
					$dumped =  Dumper $calculatedPlaying;
					$dumped =~ s/\n {44}/\n/g;   
					main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");

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

			$dataType = '2';
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

					if (exists $nowplaying->{'performers'} && $nowplaying->{'performers'} ne '') {
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'performers'});
					} elsif (exists $nowplaying->{'authors'} && $nowplaying->{'authors'} ne ''){
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'authors'});
					} elsif (exists $nowplaying->{'composers'} && $nowplaying->{'composers'} ne '') {
						$calculatedPlaying->{$station}->{'songartist'} = _lowercase($nowplaying->{'composers'});
					};
					
					if (exists $nowplaying->{'titleConcept'} && $nowplaying->{'titleConcept'} ne ''){
						# titleConcept used for programmes in a series - in which case title is the episode/instance name
						# No need to fiddle with the case as they do use mixed for this so all lowercase probably deliberate
						$calculatedPlaying->{$station}->{'songtitle'} = $nowplaying->{'titleConcept'};
					} else {
						if (exists $nowplaying->{'title'}) {$calculatedPlaying->{$station}->{'songtitle'} = _lowercase($nowplaying->{'title'})};
					}
					
					if (exists $nowplaying->{'anneeEditionMusique'}) {$calculatedPlaying->{$station}->{'songyear'} = $nowplaying->{'anneeEditionMusique'}};
					if (exists $nowplaying->{'label'}) {$calculatedPlaying->{$station}->{'songlabel'} = _lowercase($nowplaying->{'label'})};
					
					# main::DEBUGLOG && $log->is_debug && $log->debug('Preferences: DisableAlbumName='.$prefs->get('disablealbumname'));
					if (exists $nowplaying->{'titreAlbum'}) {$calculatedPlaying->{$station}->{'songalbum'} = _lowercase($nowplaying->{'titreAlbum'})};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					$thisartwork = getcover($nowplaying, $station, $info);
					
					if ($thisartwork ne ''){
						$calculatedPlaying->{$station}->{'songcover'} = $thisartwork;
					}
					
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

				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Did not find Current Song in retrieved data");

			}
			
			$dumped =  Dumper $calculatedPlaying->{$station};
			$dumped =~ s/\n {44}/\n/g;   
			main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");

		} elsif (ref($perl_data) ne "ARRAY" && 
			( exists $perl_data->{'data'}->{'now'}->{'playing_item'} ) ||
			
			( exists $perl_data->{'data'}->{'nowList'} && ref($perl_data->{'data'}->{'nowList'}) eq "ARRAY" &&
			  exists($perl_data->{'data'}->{'nowList'}[0]->{'playing_item'}) ) ) {
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


			$dataType = '3';
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
				if ((!exists $thisItem->{'title'} || !defined($thisItem->{'title'}) || $thisItem->{'title'} eq '') && 
					exists $thisItem->{'subtitle'} && defined($thisItem->{'subtitle'}) && $thisItem->{'subtitle'} ne '' )
				{	# If there is no title but there is a subtitle then this is a show not a song
				
					main::DEBUGLOG && $log->is_debug && $log->debug("$station Found programme: ".$thisItem->{'subtitle'});
					
					$calculatedPlaying->{$station}->{'progtitle'} = $thisItem->{'subtitle'};
					
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

				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Did not find Current Song in retrieved data");

			}
			
			$dumped =  Dumper $calculatedPlaying->{$station};
			$dumped =~ s/\n {44}/\n/g;   
			main::DEBUGLOG && $log->is_debug && $log->debug("Type $dataType:$dumped");
		
		} else {
			# Do not know how to parse this - probably a mistake in setup of $meta or $station
			main::INFOLOG && $log->is_info && $log->info("Called for station $station - but do know which format parser to use");
		}
	}
	
	# oh well...
	else {
		$content = '';
	}

	# Beyond this point should not use information from the data that was pulled because the code below is generic
	$dumped = Dumper $calculatedPlaying->{$station};
	# print $dumped;
	main::DEBUGLOG && $log->is_debug && $log->debug("$station - now $hiResTime data collected $dumped");

	# Hack to get around multiple stations playing the same show at the same time but info not being updated when switching to the 2nd
	# because it is the same base data
	$info->{stationid} = $station;
	
	# Note - the calculatedPlaying info contains historic data from previous runs
	# Calculate from what is thought to be playing (programme or song) and put it into $info (which reflects what we want to show)
	if ($calculatedPlaying->{$station}->{'songtitle'} ne '' && $calculatedPlaying->{$station}->{'songartist'} ne '' &&
	    $calculatedPlaying->{$station}->{'songstart'} < $hiResTime && $calculatedPlaying->{$station}->{'songend'} >= $hiResTime - cacheTTL ) {
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

			if ( (defined $info->{album} && !defined $meta->{$station}->{album}) ||
			     (!defined $info->{album} && defined $meta->{$station}->{album}) ){
				# Album presence has changed
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Album presence changed");
				$dataChanged = true;
			} elsif (defined $info->{album} && defined $meta->{$station}->{album} &&
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
