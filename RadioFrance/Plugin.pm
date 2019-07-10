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

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::RadioFrance::Settings;

# use JSON;		# JSON.pm Not installed on all LMS implementations so use LMS-friendly one below
use JSON::XS::VersionOneAndTwo;
use Encode;
use Data::Dumper;

use constant false => 0;
use constant true  => 1;



my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.radiofrance',
	'description'  => 'PLUGIN_RADIOFRANCE',
});

my $prefs = preferences('plugin.radiofrance');

use constant cacheTTL => 20;
use constant maxSongLth => 900;		# Assumed maximum song length in seconds - if appears longer then no duration shown
use constant maxShowLth => 3600;	# Assumed maximum programme length in seconds - if appears longer then no duration shown
					# because might be a problem with the data
					# Having no duration should mean earlier call back to try again

my $type3suffix = 'extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22a6f39630b68ceb8e56340a4478e099d05c9f5fc1959eaccdfb81e2ce295d82a5%22%7D%7D';

# URL for remote web site that is polled to get the information about what is playing
# Old URLs that used to work but were phased out are commented out as they might help in future if Radio France changes things again
my $urls = {
# finished 1521553005 - 2018-03-20 13:36:45	fipradio_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipradio => 'https://api.radiofrance.fr/livemeta/pull/7',
# finished 1521553005 - 2018-03-20 13:36:45	fipbordeaux_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipbordeaux => 'https://api.radiofrance.fr/livemeta/pull/7',
# finished 1521553005 - 2018-03-20 13:36:45	fipnantes_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipnantes => 'https://api.radiofrance.fr/livemeta/pull/7',
# finished 1521553005 - 2018-03-20 13:36:45	fipstrasbourg_alt => 'http://www.fipradio.fr/sites/default/files/import_si/si_titre_antenne/FIP_player_current.json',
	fipstrasbourg => 'https://api.radiofrance.fr/livemeta/pull/7',
# finished 1507650288 - 2017-10-10 16:44:48	fiprock_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_1/si_titre_antenne/FIP_player_current.json',
	fiprock => 'https://api.radiofrance.fr/livemeta/pull/64',
# finished 1507650914 - 2017-10-10 16:55:14	fipjazz_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_2/si_titre_antenne/FIP_player_current.json',
	fipjazz => 'https://api.radiofrance.fr/livemeta/pull/65',
# finished 1507650885 - 2017-10-10 16:54:45	fipgroove_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_3/si_titre_antenne/FIP_player_current.json',
	fipgroove => 'https://api.radiofrance.fr/livemeta//pull/66',
# finished 1507650800 - 2017-10-10 16:53:20	fipmonde_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_4/si_titre_antenne/FIP_player_current.json',
	fipmonde => 'https://api.radiofrance.fr/livemeta/pull/69',
# finished 1507650797 - 2017-10-10 16:53:17	fipnouveau_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_5/si_titre_antenne/FIP_player_current.json',
	fipnouveau => 'https://api.radiofrance.fr/livemeta/pull/70',
# finished 1507650800 - 2017-10-10 16:53:20	fipevenement_alt => 'http://www.fipradio.fr/sites/default/files/import_si_webradio_6/si_titre_antenne/FIP_player_current.json',
# FIP Evenement became FIP Autour Du Reggae
	fipreggae => 'https://api.radiofrance.fr/livemeta/pull/71',
	fipelectro => 'https://api.radiofrance.fr/livemeta/pull/74',
	fipmetal => 'https://api.radiofrance.fr/livemeta/pull/77',
	fmclassiqueeasy => 'https://api.radiofrance.fr/livemeta/pull/401',
	fmclassiqueplus => 'https://api.radiofrance.fr/livemeta/pull/402',
	fmconcertsradiofrance => 'https://api.radiofrance.fr/livemeta/pull/403',
	fmlajazz => 'https://api.radiofrance.fr/livemeta/pull/405',
	fmlacontemporaine => 'https://api.radiofrance.fr/livemeta/pull/406',
	fmocoramonde => 'https://api.radiofrance.fr/livemeta/pull/404',
	fmevenementielle => 'https://api.radiofrance.fr/livemeta/pull/407',
# finished	mouv_alt => 'http://www.mouv.fr/sites/default/files/import_si/si_titre_antenne/leMouv_player_current.json',
	mouv => 'https://api.radiofrance.fr/livemeta/pull/6',
	mouvxtra => 'https://api.radiofrance.fr/livemeta/pull/75',
	mouvclassics => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A601%7D&'.$type3suffix,
	mouvdancehall => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A602%7D&'.$type3suffix,
	mouvrnb => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A603%7D&'.$type3suffix,
	mouvrapus => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A604%7D&'.$type3suffix,
	mouvrapfr => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A605%7D&'.$type3suffix,
	mouv100mix => 'https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A75%7D&'.$type3suffix,
	franceinter => 'https://api.radiofrance.fr/livemeta/pull/1',
	franceinfo => 'https://api.radiofrance.fr/livemeta/pull/2',
	francemusique => 'https://api.radiofrance.fr/livemeta/pull/4',
	franceculture => 'https://api.radiofrance.fr/livemeta/pull/5',
};

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
	fmclassiqueeasy => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/aca436ad-7f99-4765-9404-1b04bf216daf/fmwebradiosnormaleasy.jpg',
	fmclassiqueplus => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/b8213b77-465c-487e-b5b6-07ce8e2862df/fmwebradiosnormalplus.jpg',
	fmconcertsradiofrance => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/72f1a384-5b04-4b98-b511-ac07b35c7daf/fmwebradiosnormalconcerts.jpg',
	fmlajazz => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/a2d34823-36a1-4fce-b3fa-f0579e056552/fmwebradiosnormaljazz.jpg',
	fmlacontemporaine => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/92f9a1f4-5525-4b2a-af13-213ff3b0c0a6/fmwebradiosnormalcontemp.jpg',
	fmocoramonde => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/22b8b3d6-e848-4090-8b24-141c25225861/fmwebradiosnormalocora.jpg',
	fmevenementielle => 'https://s3-eu-west-1.amazonaws.com/cruiser-production/2016/12/c3ca5137-44d4-45fd-b23f-62957d7f52e3/fmwebradiosnormalkids.jpg',
	mouv => 'https://www.radiofrance.fr/sites/default/files/offre_logo_mouv_2015.jpg',
	mouvxtra => 'http://www.mouv.fr/sites/all/modules/rf/rf_lecteur_commun/lecteur_rf/img/logo_mouv_xtra.png',
	mouvclassics => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/bb8da8da-f679-405f-8810-b4a172f6a32d/300x300_mouv-classic_02.jpg',
	mouvdancehall => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/9d04e918-c907-4627-a332-1071bdc2366e/300x300_dancehall.jpg',
	mouvrnb => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/f3bf764e-637c-48c0-b152-1a258726710f/300x300_rnb.jpg',
	mouvrapus => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/54f3a745-fcf5-4f62-885a-a014cdd50a62/300x300_rapus.jpg',
	mouvrapfr => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/3c4dc967-ed2c-4ce5-a998-9437a64e05d5/300x300_rapfr.jpg',
	mouv100mix => 'https://cdn.radiofrance.fr/s3/cruiser-production/2019/01/689453b1-de6c-4c9e-9ebd-de70d0220e69/300x300_mouv-100mix-final.jpg',
	franceinter => 'https://www.radiofrance.fr/sites/default/files/atoms/images/offre_logo_inter.jpg',
	franceinfo => 'https://www.radiofrance.fr/sites/default/files/atoms/images/offre_logo_franceinfo.jpg',
	francemusique => 'https://www.radiofrance.fr/sites/default/files/atoms/images/offre_logo_france_musique.jpg',
	franceculture => 'https://www.radiofrance.fr/sites/default/files/atoms/images/offre_logo_france_culture.jpg',
};

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
	fmclassiqueeasy => '(dummy)',
	fmclassiqueplus => '(dummy)',
	fmconcertsradiofrance => '(dummy)',
	fmlajazz => '(dummy)',
	fmlacontemporaine => '(dummy)',
	fmocoramonde => '(dummy)',
	fmevenementielle => '(dummy)',
	mouv => '(image_default_player.jpg)',
	mouvxtra => '(image_default_player.jpg)',
	mouvclassics => '(image_default_player.jpg)',
	mouvdancehall => '(image_default_player.jpg)',
	mouvrnb => '(image_default_player.jpg)',
	mouvrapus => '(image_default_player.jpg)',
	mouvrapfr => '(image_default_player.jpg)',
	mouv100mix => '(image_default_player.jpg)',
	franceinter => '(dummy)',
	franceinfo => '(dummy)',
	francemusique => '(dummy)',
	franceculture => '(dummy)',
};

# Uses match group 1 from regex call to try to find station
my %stationMatches = (
	"id=s15200&", "fipradio",
	"id=s50706&", "fipbordeaux",
	"id=s50770&", "fipnantes",
	"id=s111944&", "fipstrasbourg",
	"id=s262528&", "fiprock",
	"id=s262533&", "fipjazz",
	"id=s262537&", "fipgroove",
	"id=s262538&", "fipmonde",
	"id=s262540&", "fipnouveau",
	"id=s293090&", "fipreggae",
	"id=s293089&", "fipelectro",
	"id=s308366&", "fipmetal",
	"id=s283174&", "fmclassiqueeasy",
	"id=s283175&", "fmclassiqueplus",
	"id=s283176&", "fmconcertsradiofrance",
	"id=s283178&", "fmlajazz",
	"id=s283179&", "fmlacontemporaine",
	"id=s283177&", "fmocoramonde",
	"id=s285660&", "fmevenementielle",
	"id=s6597&", "mouv",
	# gone - taken over by Mouv 100% Mix "id=s244069&", "mouvxtra",
	"id=s307696&", "mouvclassics",
	"id=s307697&", "mouvdancehall",
	"id=s307695&", "mouvrnb",
	"id=s307694&", "mouvrapus",
	"id=s307693&", "mouvrapfr",
	"id=s244069&", "mouv100mix",
	"id=s24875&", "franceinter",
	"id=s9948&", "franceinfo",
	"id=s15198&", "francemusique",
	"id=s2442&", "franceculture",
	
	
	"fip-", "fipradio",
	"fipbordeaux-", "fipbordeaux",
	"fipnantes-", "fipnantes",
	"fipstrasbourg-", "fipstrasbourg",
	"fip-webradio1.", "fiprock",
	"fip-webradio2.", "fipjazz",
	"fip-webradio3.", "fipgroove",
	"fip-webradio4.", "fipmonde",
	"fip-webradio5.", "fipnouveau",
	"fip-webradio6.", "fipreggae",
	"fip-webradio8.", "fipelectro",
	"fip-webradio7.", "fipmetal",
	"francemusiqueeasyclassique-", "fmclassiqueeasy",
	"francemusiqueclassiqueplus-", "fmclassiqueplus",
	"francemusiqueconcertsradiofrance-", "fmconcertsradiofrance",
	"francemusiquelajazz-", "fmlajazz",
	"francemusiquelacontemporaine-", "fmlacontemporaine",
	"francemusiqueocoramonde-", "fmocoramonde",
	"francemusiquelevenementielle-", "fmevenementielle",
	"mouv-", "mouv",
	"mouvxtra-", "mouvxtra",
	"mouvclassics-", "mouvclassics",
	"mouvdancehall-", "mouvdancehall",
	"mouvrnb-", "mouvrnb",
	"mouvrapus-", "mouvrapus",
	"mouvrapfr-", "mouvrapfr",
	"mouv100p100mix-", "mouv100mix",
	"franceinter-","franceinter",
	"franceinfo-","franceinfo",
	"francemusique-","francemusique",
	"franceculture-","franceculture",
);

# $meta holds info about station that is playing - note - the structure is returned to others parts of LMS where particular field names are expected
# If you add fields to this then you probably will have to preserve it in parseContent
my $meta = {
    dummy => { title => '' },
	fipradio => { busy => 0, title => 'FIP', icon => $icons->{fipradio}, cover => $icons->{fipradio}, ttl => 0, endTime => 0 },
	fipbordeaux => { busy => 0, title => 'FIP Bordeaux', icon => $icons->{fipbordeaux}, cover => $icons->{fipbordeaux}, ttl => 0, endTime => 0 },
	fipnantes => { busy => 0, title => 'FIP Nantes', icon => $icons->{fipnantes}, cover => $icons->{fipnantes}, ttl => 0, endTime => 0 },
	fipstrasbourg => { busy => 0, title => 'FIP Strasbourg', icon => $icons->{fipstrasbourg}, cover => $icons->{fipstrasbourg}, ttl => 0, endTime => 0 },
	fiprock => { busy => 0, title => 'FIP Rock', icon => $icons->{fiprock}, cover => $icons->{fiprock}, ttl => 0, endTime => 0 },
	fipjazz => { busy => 0, title => 'FIP Jazz', icon => $icons->{fipjazz}, cover => $icons->{fipjazz}, ttl => 0, endTime => 0 },
	fipgroove => { busy => 0, title => 'FIP Groove', icon => $icons->{fipgroove}, cover => $icons->{fipgroove}, ttl => 0, endTime => 0 },
	fipmonde => { busy => 0, title => 'FIP Monde', icon => $icons->{fipmonde}, cover => $icons->{fipmonde}, ttl => 0, endTime => 0 },
	fipnouveau => { busy => 0, title => 'Tout nouveau, tout Fip', icon => $icons->{fipnouveau}, cover => $icons->{fipnouveau}, ttl => 0, endTime => 0 },
	fipreggae => { busy => 0, title => 'FIP Reggae', icon => $icons->{fipreggae}, cover => $icons->{fipreggae}, ttl => 0, endTime => 0 },
	fipelectro => { busy => 0, title => 'FIP Electro', icon => $icons->{fipelectro}, cover => $icons->{fipelectro}, ttl => 0, endTime => 0 },
	fipmetal => { busy => 0, title => 'FIP L\'été Metal', icon => $icons->{fipmetal}, cover => $icons->{fipmetal}, ttl => 0, endTime => 0 },
	fmclassiqueeasy => { busy => 0, title => 'France Musique Classique Easy', icon => $icons->{fmclassiqueeasy}, cover => $icons->{fmclassiqueeasy}, ttl => 0, endTime => 0 },
	fmclassiqueplus => { busy => 0, title => 'France Musique Classique Plus', icon => $icons->{fmclassiqueplus}, cover => $icons->{fmclassiqueplus}, ttl => 0, endTime => 0 },
	fmconcertsradiofrance => { busy => 0, title => 'France Musique Concerts', icon => $icons->{fmconcertsradiofrance}, cover => $icons->{fmconcertsradiofrance}, ttl => 0, endTime => 0 },
	fmlajazz => { busy => 0, title => 'France Musique La Jazz', icon => $icons->{fmlajazz}, cover => $icons->{fmlajazz}, ttl => 0, endTime => 0 },
	fmlacontemporaine => { busy => 0, title => 'France Musique La Contemporaine', icon => $icons->{fmlacontemporaine}, cover => $icons->{fmlacontemporaine}, ttl => 0, endTime => 0 },
	fmocoramonde => { busy => 0, title => 'France Musique Ocora Monde', icon => $icons->{fmocoramonde}, cover => $icons->{fmocoramonde}, ttl => 0, endTime => 0 },
	fmevenementielle => { busy => 0, title => 'France Musique Classique Kids', icon => $icons->{fmevenementielle}, cover => $icons->{fmevenementielle}, ttl => 0, endTime => 0 },
	mouv => { busy => 0, title => 'Mouv\'', icon => $icons->{mouv}, cover => $icons->{mouv}, ttl => 0, endTime => 0 },
	mouvxtra => { busy => 0, title => 'Mouv\' Xtra', icon => $icons->{mouvxtra}, cover => $icons->{mouvxtra}, ttl => 0, endTime => 0 },
	mouvclassics => { busy => 0, title => 'Mouv\' Classics', icon => $icons->{mouvclassics}, cover => $icons->{mouvclassics}, ttl => 0, endTime => 0 },
	mouvdancehall => { busy => 0, title => 'Mouv\' Dancehall', icon => $icons->{mouvdancehall}, cover => $icons->{mouvdancehall}, ttl => 0, endTime => 0 },
	mouvrnb => { busy => 0, title => 'Mouv\' R\'N\'B', icon => $icons->{mouvrnb}, cover => $icons->{mouvrnb}, ttl => 0, endTime => 0 },
	mouvrapus => { busy => 0, title => 'Mouv\' RAP US', icon => $icons->{mouvrapus}, cover => $icons->{mouvrapus}, ttl => 0, endTime => 0 },
	mouvrapfr => { busy => 0, title => 'Mouv\' RAP Français', icon => $icons->{mouvrapfr}, cover => $icons->{mouvrapfr}, ttl => 0, endTime => 0 },
	mouv100mix => { busy => 0, title => 'Mouv\' 100\% Mix', icon => $icons->{mouv100mix}, cover => $icons->{mouv100mix}, ttl => 0, endTime => 0 },
	franceinter => { busy => 0, title => 'France Inter', icon => $icons->{franceinter}, cover => $icons->{franceinter}, ttl => 0, endTime => 0 },
	franceinfo => { busy => 0, title => 'France Info', icon => $icons->{franceinfo}, cover => $icons->{franceinfo}, ttl => 0, endTime => 0 },
	francemusique => { busy => 0, title => 'France Musique', icon => $icons->{francemusique}, cover => $icons->{francemusique}, ttl => 0, endTime => 0 },
	franceculture => { busy => 0, title => 'France Culture', icon => $icons->{franceculture}, cover => $icons->{franceculture}, ttl => 0, endTime => 0 },
};

# $myClientInfo holds data about the clients/devices using this plugin - used to schedule next poll
my $myClientInfo = {};

# FIP via TuneIn
# http://opml.radiotime.com/Tune.ashx?id=s15200&formats=aac,ogg,mp3,wmpro,wma,wmvoice&partnerId=16
# Played via direct URL like ... http://direct.fipradio.fr/live/fip-midfi.mp3 which redirects to something with same suffix
# Match group 1 is used to find station id in %stationMatches - "fip-" last because it is a substring of others
my $urlRegex1 = qr/(?:\/)(fipbordeaux-|fipnantes-|fipstrasbourg-|fip-webradio1\.|fip-webradio2\.|fip-webradio3\.|fip-webradio4\.|fip-webradio5\.|fip-webradio6\.|fip-webradio8\.|fip-webradio7\.|fip-|francemusiqueeasyclassique-|francemusiqueclassiqueplus-|francemusiqueconcertsradiofrance-|francemusiquelajazz-|francemusiquelacontemporaine-|francemusiqueocoramonde-|francemusiquelevenementielle-|mouv-|mouvxtra-|mouvclassics-|mouvdancehall-|mouvrnb-|mouvrapus-|mouvrapfr-|mouv100p100mix-|franceinter-)(?:midfi|lofi|hifi|)/i;
# Selected via TuneIn base|bordeaux|nantes|strasbourg|rock|jazz|groove|monde|nouveau|reggae|electro|metal FranceMusique - ClassicEasy|ClassicPlus|Concerts|Contemporaine|OcoraMonde|ClassiqueKids/Evenementielle - Mouv|classics|dancehall|rnb|rapus|rapfr|100mix
my $urlRegex2 = qr/(?:radiotime|tunein)\.com.*(id=s15200&|id=s50706&|id=s50770&|id=s111944&|id=s262528&|id=s262533&|id=s262537&|id=s262538&|id=s262540&|id=s293090&|id=s293089&|id=s308366&|id=s283174&|id=s283175&|id=s283176&|id=s283178&|id=s283179&|id=s283177&|id=s285660&|id=s6597&|id=s244069&|id=s307693&|id=s307694&|id=s307695&|id=s307696&|id=s307697&)/i;
# 2nd pair is for non-song-based stations so that they can be optionally disabled
my $urlRegexNonSong1 = qr/(?:\/)(franceinter-|franceinfo-|francemusique-|franceculture-)(?:midfi|lofi|hifi|)/i;
# Selected via TuneIn franceinter|franceinfo|francemusique|franceculture
my $urlRegexNonSong2 = qr/(?:radiotime|tunein)\.com.*(id=s24875&|id=s9948&|id=s15198&|id=s2442&)/i;


sub getDisplayName {
	return 'PLUGIN_RADIOFRANCE';
}

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

	if ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		# Warn if HTTPS support not present because some of the meta provider URLs redirect to https (since February 2018)
		$log->error(string('PLUGIN_RADIOFRANCE_MISSING_SSL'));
	}

	Slim::Formats::RemoteMetadata->registerParser(
		match => $urlRegex2,
		func  => \&parser,
	);

	Slim::Formats::RemoteMetadata->registerParser(
		match => $urlRegex1,
		func  => \&parser,
	);

	Slim::Formats::RemoteMetadata->registerProvider(
		match => $urlRegex2,
		func  => \&provider,
	);

	Slim::Formats::RemoteMetadata->registerProvider(
		match => $urlRegex1,
		func  => \&provider,
	);

	if (!$prefs->get('excludesomestations')){
		Slim::Formats::RemoteMetadata->registerParser(
			match => $urlRegexNonSong2,
			func  => \&parser,
		);

		Slim::Formats::RemoteMetadata->registerParser(
			match => $urlRegexNonSong1,
			func  => \&parser,
		);
		
		Slim::Formats::RemoteMetadata->registerProvider(
			match => $urlRegexNonSong2,
			func  => \&provider,
		);

		Slim::Formats::RemoteMetadata->registerProvider(
			match => $urlRegexNonSong1,
			func  => \&provider,
		);
	}
	
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
	$prefs = preferences('plugin.radiofrance');
	
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
	
	$testUrl =~ $urlRegex2;
	
	# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 2 received for $testUrl");

	if ($testUrl && exists $stationMatches{$testUrl}) {
		# Found a match so take this station
		$station = $stationMatches{$testUrl};
	} else {
		# Try other match
		$testUrl = $url;
		$testUrl =~ $urlRegex1;
		
		if ($1) {$testUrl = lc($1);}
		
		# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 3 received for $testUrl");
		
		if (exists $stationMatches{$testUrl}) {
			# Found a match so take this station
			$station = $stationMatches{$testUrl};
		}		
	}

	if ($station eq '' && !$prefs->get('excludesomestations')){
		# Not found yet - so try the other sets
		# ###ToDo### Optimise this by looping through all sets rather than sets of if/then/else
		
		# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 4 received for $url");
		$testUrl = $url;
		$testUrl =~ $urlRegexNonSong2;
		
		# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 5 received for $testUrl");

		if ($testUrl && exists $stationMatches{$testUrl}) {
			# Found a match so take this station
			$station = $stationMatches{$testUrl};
		} else {
			# Try other match
			$testUrl = $url;
			$testUrl =~ $urlRegexNonSong1;
			
			if ($1) {$testUrl = lc($1);}
			
			# main::DEBUGLOG && $log->is_debug && $log->debug("Checking data 6 received for $testUrl");
			
			if (exists $stationMatches{$testUrl}) {
				# Found a match so take this station
				$station = $stationMatches{$testUrl};
			}		
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


sub getmeta {
	
	my ( $client, $url, $fromProvider) = @_;
	
	$prefs = preferences('plugin.radiofrance');
	
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
		if ( $client->isPlaying && (!$meta->{$station} || $meta->{$station}->{ttl} <= $hiResTime) && !$meta->{$station}->{busy} ) {
			
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
			
			main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching data from $sourceUrl");
			$http->get($sourceUrl);
			
			if (exists $urls->{$station."_alt"}){
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
				$meta->{$station}->{busy} = $meta->{$station}->{busy}+1;	# Increment busy counter - might be possible that the one above already finished so increment rather than set to 2
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Fetching alternate data from $sourceUrl");
				$httpalt->get($sourceUrl);
			}

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
		$station = &matchStation( $playingURL );
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
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("$station - parseContent - no device name");
	} else {
		$deviceName = $client->name;
	};
	
	my $dumped;
	
	# main::DEBUGLOG && $log->is_debug && $log->debug("About to parseContent");
	

	if (defined($content) && $content ne ''){
	
		# main::DEBUGLOG && $log->is_debug && $log->debug("About to decode JSON");
		
		my $perl_data = eval { from_json( $content ) };

		# $dumped =  Dumper $perl_data;
		# $dumped =~ s/\n {44}/\n/g;   
		# print $dumped;
		
		if (exists $perl_data->{'current'}->{'song'} || $perl_data->{'current'}->{'emission'}){
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
			
			
			
			my $nowplaying = $perl_data->{'current'}->{'song'};

			if (exists $perl_data->{'current'}->{'emission'}->{'startTime'} && exists $perl_data->{'current'}->{'emission'}->{'endTime'} &&
				$hiResTime >= $perl_data->{'current'}->{'emission'}->{'startTime'} && $hiResTime <= $perl_data->{'current'}->{'emission'}->{'endTime'}+30) {
				# Station / Programme name provided so use that if it is on now - e.g. gives real current name for FIP Evenement
			
				if (exists $perl_data->{'current'}->{'emission'}->{'titre'} && $perl_data->{'current'}->{'emission'}->{'titre'} ne ''){
					$info->{remote_title} = $perl_data->{'current'}->{'emission'}->{'titre'};
					$info->{remotetitle} = $info->{remote_title};
					# Also set it at the track title for now - since the others above do not have any visible effect on device displays
					# Will be overwritten if there is a real song available
					$info->{title} = $info->{remote_title};
				}
				
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
						$info->{cover} = $progIcon;
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
				
				if (exists $nowplaying->{'startTime'}){ $info->{startTime} = $nowplaying->{'startTime'}};
				
				my $expectedEndTime = $hiResTime;
				
				if (exists $nowplaying->{'endTime'}){ $expectedEndTime = $nowplaying->{'endTime'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

					if (exists $nowplaying->{'interpreteMorceau'}) {$info->{artist} = _lowercase($nowplaying->{'interpreteMorceau'})};
					if (exists $nowplaying->{'titre'}) {$info->{title} = _lowercase($nowplaying->{'titre'})};
					if (exists $nowplaying->{'anneeEditionMusique'}) {$info->{year} = $nowplaying->{'anneeEditionMusique'}};
					if (exists $nowplaying->{'label'}) {$info->{label} = _lowercase($nowplaying->{'label'})};
					
					# main::DEBUGLOG && $log->is_debug && $log->debug('Preferences: DisableAlbumName='.$prefs->get('disablealbumname'));
					if (!$prefs->get('disablealbumname')){
						if (exists $nowplaying->{'titreAlbum'}) {$info->{album} = _lowercase($nowplaying->{'titreAlbum'})};
					}
					
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
						$info->{cover} = $thisartwork;
					} else {
						# Icon not present or matches one to be ignored
						# main::DEBUGLOG && $log->is_debug && $log->debug("Image:\n small: ".$nowplaying->{'visuel'}->{small}."\n medium: ".$nowplaying->{'visuel'}->{medium});
					}
					
					if ( exists $nowplaying->{'endTime'} && exists $nowplaying->{'startTime'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'endTime'} - $nowplaying->{'startTime'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0 && $songDuration < maxSongLth && !$hideDuration) {$info->{duration} = $songDuration};
					}
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$info->{endTime} = $expectedEndTime;
					
					$dumped =  Dumper $info;
					$dumped =~ s/\n {44}/\n/g;   
					main::DEBUGLOG && $log->is_debug && $log->debug("Type1:$dumped");

				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				# print("Did not find Current Song in retrieved data");

			}
		} elsif (exists $perl_data->{'levels'}){
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
										if (exists $thisItem->{'title'} && $thisItem->{'title'} ne '' && 
										    exists $thisItem->{'embedType'} && $thisItem->{'embedType'} ne 'song' &&
										    (!exists $thisItem->{'authors'} || ref($thisItem->{'authors'}) eq 'ARRAY') && !exists $thisItem->{'performers'} && !exists $thisItem->{'composers'})
										{	# If there is a title but no authors/performers/composers then this is a show not a song
										
											main::DEBUGLOG && $log->is_debug && $log->debug("$station Found programme: ".$thisItem->{'title'});
											
											my $parentTitle = '';
											
											if (!$prefs->get('excludesynopsis') && (!exists $info->{album} || $info->{album} eq '')){
												if (exists $thisItem->{'expressionDescription'} && 
												   $thisItem->{'expressionDescription'} ne '' && 
												   $thisItem->{'expressionDescription'} ne '...')
												{
													# If not already collected an "album" (synopsis in this case) then take this one
													$info->{album} = $thisItem->{'expressionDescription'};
												} elsif (exists $thisItem->{'description'} && $thisItem->{'description'} ne ''){
													# Try Description instead
													$info->{album} = $thisItem->{'description'};
												}
											}

											$info->{remote_title} = $thisItem->{'title'};
											
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
													
													if (!$prefs->get('excludesynopsis') && (!exists $info->{album} || $info->{album} eq '')){
														if (exists $perl_data->{steps}->{$parentItem}->{'expressionDescription'} && 
														    $perl_data->{steps}->{$parentItem}->{'expressionDescription'} ne '' && 
														    $perl_data->{steps}->{$parentItem}->{'expressionDescription'} ne '...')
														{
															# If not already collected an "album" (synopsis in this case) then take this one
															$info->{album} = $perl_data->{steps}->{$parentItem}->{'expressionDescription'};
														} elsif (exists $perl_data->{steps}->{$parentItem}->{'description'} && $perl_data->{steps}->{$parentItem}->{'description'} ne ''){
															# Try Description instead
															$info->{album} = $perl_data->{steps}->{$parentItem}->{'description'};
														}
													}
												}
											}
											
											if ($parentTitle ne ''){
												# Have both fields - but only include first if not already included in second to reduce line length to reduce chance of scrolling
												if ($thisItem->{'title'} !~ /^\Q$parentTitle\E/i ){
													$info->{remote_title} = $parentTitle." / ".$thisItem->{'title'};
												}
											
												main::DEBUGLOG && $log->is_debug && $log->debug("$station Found subprogramme: ".$info->{remote_title});
											}
											
											$info->{remotetitle} = $info->{remote_title};
											# Also set it at the track title for now - since the others above do not have any visible effect on device displays
											# Will be overwritten if there is a real song available
											$info->{title} = $info->{remote_title};
											
											if (exists $thisItem->{'start'}){ $info->{startTime} = $thisItem->{'start'}};
											if (exists $thisItem->{'end'}){ $info->{endTime} = $thisItem->{'end'}};
											
											if ( exists $thisItem->{'end'} && exists $thisItem->{'start'} ){
												# Work out programme duration and return if plausible
												$progDuration = $thisItem->{'end'} - $thisItem->{'start'};
												
												# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Show Duration $progDuration");
												
												if ($progDuration > 0 && $progDuration < maxShowLth && !$hideDuration) {$info->{duration} = $progDuration};
											}

											
											main::DEBUGLOG && $log->is_debug && $log->debug("Found show name in Type2: $info->{title}\n");
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
				
				if (exists $nowplaying->{'start'}){ $info->{startTime} = $nowplaying->{'start'}};
				
				my $expectedEndTime = $hiResTime;
				
				if (exists $nowplaying->{'end'}){ $expectedEndTime = $nowplaying->{'end'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

					if (exists $nowplaying->{'performers'} && $nowplaying->{'performers'} ne '') {
						$info->{artist} = _lowercase($nowplaying->{'performers'});
					} elsif (exists $nowplaying->{'authors'} && $nowplaying->{'authors'} ne ''){
						$info->{artist} = _lowercase($nowplaying->{'authors'});
					} elsif (exists $nowplaying->{'composers'} && $nowplaying->{'composers'} ne '') {
						$info->{artist} = _lowercase($nowplaying->{'composers'});
					};
					
					if (exists $nowplaying->{'titleConcept'} && $nowplaying->{'titleConcept'} ne ''){
						# titleConcept used for programmes in a series - in which case title is the episode/instance name
						# No need to fiddle with the case as they do use mixed for this so all lowercase probably deliberate
						$info->{title} = $nowplaying->{'titleConcept'};
					} else {
						if (exists $nowplaying->{'title'}) {$info->{title} = _lowercase($nowplaying->{'title'})};
					}
					
					if (exists $nowplaying->{'anneeEditionMusique'}) {$info->{year} = $nowplaying->{'anneeEditionMusique'}};
					if (exists $nowplaying->{'label'}) {$info->{label} = _lowercase($nowplaying->{'label'})};
					
					# Force the album name ... just in case one was collected as part of programme details but now in a song
					if (exists $info->{album}) {delete $info->{album}};
					
					# main::DEBUGLOG && $log->is_debug && $log->debug('Preferences: DisableAlbumName='.$prefs->get('disablealbumname'));
					if (!$prefs->get('disablealbumname')){
						if (exists $nowplaying->{'titreAlbum'}) {$info->{album} = _lowercase($nowplaying->{'titreAlbum'})};
					}
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					if ($nowplaying->{'visual'}){
						$thisartwork = $nowplaying->{'visual'};
					}
					
					if (($thisartwork ne '' && ($thisartwork !~ /$iconsIgnoreRegex->{$station}/ || $thisartwork eq $info->{icon})) &&
					     ($thisartwork =~ /^https?:/i)){
					     # There is something, it is not excluded, it is not the station logo and it appears to be a URL
						$info->{cover} = $thisartwork;
					} else {
						# Icon not present or matches one to be ignored
						# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$nowplaying->{'visual'});
					}
					
					if ( exists $nowplaying->{'end'} && exists $nowplaying->{'start'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'end'} - $nowplaying->{'start'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0 && $songDuration < maxSongLth && !$hideDuration) {$info->{duration} = $songDuration};
					}
					
					$info->{remote_title} = $info->{title};
					$info->{remotetitle} = $info->{title};
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$info->{endTime} = $expectedEndTime;
					
				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Did not find Current Song in retrieved data");

			}
			
			$dumped =  Dumper $info;
			$dumped =~ s/\n {44}/\n/g;   
			main::DEBUGLOG && $log->is_debug && $log->debug("Type2:$dumped");

		} elsif (exists $perl_data->{'data'}->{'now'}->{'playing_item'}) {
			# Sample response from Mouv' additional stations (from Feb-2019)
			# Note - do not know where the sha1 ref for the persistent search comes from but seems to be consistent across stations
			# https://www.mouv.fr/latest/api/graphql?operationName=NowWebradio&variables=%7B%22stationId%22%3A605%7D&extensions=%7B%22persistedQuery%22%3A%7B%22version%22%3A1%2C%22sha256Hash%22%3A%22a6f39630b68ceb8e56340a4478e099d05c9f5fc1959eaccdfb81e2ce295d82a5%22%7D%7D
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

			my $nowplaying;
			my $thisItem;
			
			# Try to find what is playing (priority to song over programme)
			$thisItem = $perl_data->{'data'}->{'now'}->{'playing_item'};
			
			# main::DEBUGLOG && $log->is_debug && $log->debug("Now: $hiResTime Start: ".$thisitem->{'start_time'}." End: $thisitem->{'end_time'}");
			
			if ( exists $thisItem->{'start_time'} && $thisItem->{'start_time'} <= $hiResTime && 
				exists $thisItem->{'end_time'} && $thisItem->{'end_time'} >= $hiResTime ) {
				# This is in range
				# main::DEBUGLOG && $log->is_debug && $log->debug("Current playing $thisItem");
				if ((!exists $thisItem->{'title'} || !defined($thisItem->{'title'}) || $thisItem->{'title'} eq '') && 
					exists $thisItem->{'subtitle'} && defined($thisItem->{'subtitle'}) && $thisItem->{'subtitle'} ne '' )
				{	# If there is no title but there is a subtitle then this is a show not a song
				
					main::DEBUGLOG && $log->is_debug && $log->debug("$station Found programme: ".$thisItem->{'subtitle'});
					
					$info->{remote_title} = $thisItem->{'subtitle'};
					$info->{remotetitle} = $info->{remote_title};
					# Also set it at the track title for now - since the others above do not have any visible effect on device displays
					# Will be overwritten if there is a real song available
					$info->{title} = $info->{remote_title};
					
					if (exists $thisItem->{'start_time'}){ $info->{startTime} = $thisItem->{'start_time'}};
					if (exists $thisItem->{'end_time'}){ $info->{endTime} = $thisItem->{'end_time'}};
					
					if ( exists $thisItem->{'end_time'} && exists $thisItem->{'start_time'} ){
						# Work out programme duration and return if plausible
						$progDuration = $thisItem->{'end_time'} - $thisItem->{'start_time'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Show Duration $progDuration");
						
						if ($progDuration > 0 && $progDuration < maxShowLth && !$hideDuration) {$info->{duration} = $progDuration};
					}

					
					main::DEBUGLOG && $log->is_debug && $log->debug("Found show name in Type3: $info->{title}\n");
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
				
				if (exists $nowplaying->{'start_time'}){ $info->{startTime} = $nowplaying->{'start_time'}};
				
				my $expectedEndTime = $hiResTime;
				
				if (exists $nowplaying->{'end_time'}){ $expectedEndTime = $nowplaying->{'end_time'}};
				
				if ( $expectedEndTime > $hiResTime-30 ){
					# If looks like this should not have already finished (allowing for some leniency for clock drift and other delays) then get the details
					# This requires that the time on the machine running LMS should be accurate - and timezone set correctly

					if (exists $nowplaying->{'title'} && defined($nowplaying->{'title'}) && $nowplaying->{'title'} ne '') {
						$info->{artist} = _lowercase($nowplaying->{'title'});
					}
					
					if (exists $nowplaying->{'subtitle'} && defined($nowplaying->{'subtitle'}) && $nowplaying->{'subtitle'} ne '') {$info->{title} = _lowercase($nowplaying->{'subtitle'})};
					
					# Artwork - only include if not one of the defaults - to give chance for something else to add it
					# Regex check to see if present using $iconsIgnoreRegex
					my $thisartwork = '';
					
					if ($nowplaying->{'cover'}){
						$thisartwork = $nowplaying->{'cover'};
					}
					
					if (($thisartwork ne '' && ($thisartwork !~ /$iconsIgnoreRegex->{$station}/ || $thisartwork eq $info->{icon})) &&
					     ($thisartwork =~ /^https?:/i)){
					     # There is something, it is not excluded, it is not the station logo and it appears to be a URL
						$info->{cover} = $thisartwork;
					} else {
						# Icon not present or matches one to be ignored
						# main::DEBUGLOG && $log->is_debug && $log->debug("Image: ".$nowplaying->{'visual'});
					}
					
					if ( exists $nowplaying->{'end_time'} && exists $nowplaying->{'start_time'} ){
						# Work out song duration and return if plausible
						$songDuration = $nowplaying->{'end_time'} - $nowplaying->{'start_time'};
						
						# main::DEBUGLOG && $log->is_debug && $log->debug("$station - Duration $songDuration");
						
						if ($songDuration > 0 && $songDuration < maxSongLth && !$hideDuration) {$info->{duration} = $songDuration};
					}
					
					$info->{remote_title} = $info->{title};
					$info->{remotetitle} = $info->{title};
					
					# Try to update the predicted end time to give better chance for timely display of next song
					$info->{endTime} = $expectedEndTime;
					
				} else {
					# This song that is playing should have already finished so returning largely blank data should reset what is displayed
					main::DEBUGLOG && $log->is_debug && $log->debug("$station - Song already finished - expected end $expectedEndTime and now $hiResTime");
				}

			} else {

				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Did not find Current Song in retrieved data");

			}
			
			$dumped =  Dumper $info;
			$dumped =~ s/\n {44}/\n/g;   
			main::DEBUGLOG && $log->is_debug && $log->debug("Type3:$dumped");

		
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

			# Just in case ...
			if ( defined $info->{year} && !defined $meta->{$station}->{year} ){
				# looks like we have label and did not before
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Enriching with year: ".$info->{year});
				$dataChanged = true;
			} elsif (!defined $info->{year} && defined $meta->{$station}->{year}){
				# Had year before but do not now - so preserve old
				$info->{year} = $meta->{$station}->{year};
				main::DEBUGLOG && $log->is_debug && $log->debug("$station - Client: $deviceName - Preserving previously collected year: ".$info->{year});
			}
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
			if (defined $meta->{$station}->{cover}) {$info->{cover} = $meta->{$station}->{cover}};
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
	
	my $thisartist = '';
	my $thistitle = '';
	my $thiscover = '';
	my $thisicon = '';
		
	if (defined $info->{artist}) {$thisartist = $info->{artist}};
	if (defined $info->{title}) {$thistitle = $info->{title}};
	if (defined $info->{cover}) {$thiscover = $info->{cover}};
	if (defined $info->{icon}) {$thisicon = $info->{icon}};

	if ($prefs->get('appendlabel') && defined $info->{album} && defined $info->{label}){
		# Been asked to add the record label name to album name if present
		my $appendStr = ' / '.$info->{label};
		# Only add it if not already there (could happen when more than one data source)
		# Note - might not be the last field on the line because of Year below so do not test for EOL $)
		if ($info->{album} !~ m/\Q$appendStr\E/){
			$info->{album} .= $appendStr;
		}
	}

	if ($prefs->get('appendyear') && defined $info->{album} && defined $info->{year}){
		# Been asked to add the year to album name if present
		my $appendStr = ' / '.$info->{year};
		# Only add it if not already there (could happen when more than one data source)
		if ($info->{album} !~ m/\Q$appendStr\E$/){
			$info->{album} .= $appendStr;
		}
	}
	
	my $deviceName = "";
	
	if (!$client->name){
		# No name present - this is odd
		main::DEBUGLOG && $log->is_debug && $log->debug("no device name");
	} else {
		$deviceName = $client->name;
	};

	my $lastartist = '';
	my $lasttitle = '';
	if (defined $myClientInfo->{$deviceName}->{lastartist}) {$lastartist = $myClientInfo->{$deviceName}->{lastartist}};
	if (defined $myClientInfo->{$deviceName}->{lasttitle}) {$lasttitle = $myClientInfo->{$deviceName}->{lasttitle}};
	
	if ($song && ($lastartist ne $thisartist || $lasttitle ne $thistitle)) {
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

			$song->pluginData( wmaMeta => $info );
			# $client->master->pluginData( metadata => $info );
			
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
			$myClientInfo->{$deviceName}->{lastpush} = $hiResTime;
			$myClientInfo->{$deviceName}->{lastartist} = $thisartist;
			$myClientInfo->{$deviceName}->{lasttitle} = $thistitle;
	}
}


sub deviceTimer {

	my ( $client, $info, $url ) = @_;
	
	my $hiResTime = getLocalAdjustedTime+$prefs->get('streamdelay');	# Use real time (not adjusted) because will be setting real timer
	
	my $station = &matchStation( $url );
	
	my $deviceName = "";
	
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
	} else {
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
