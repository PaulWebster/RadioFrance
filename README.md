---
layout: page
title: RadioFrance - Slimerver/LMS PlugIn to get song information and replay past programmes from Radio France stations
---

Slimerver/LMS PlugIn to get song information and replay past programmes from Radio France stations
=========================================

Display artist, track, cover and, optionally, album name, label and year for:
* FIP (http://www.fipradio.fr) stations (including web stations such as Jazz)
* France Musique (http://www.francemusique.fr) web stations (such as Ocora and Classique Plus)
* Mouv' (http://www.mouv.fr)
Display programme name, segment name (when available) and synopsis (when available) for:
* France Inter, France Info, France Musique, France Culture and France Blue (40+ stations)
Browse station schedule by date to select old programmes and segments for replay
* Note - very limited content from FIP and none from web-only stations

This software is licensed under the GPL.

## Requirements

This plugin requires Logitech Media Server v7.5.0 or greater.

## Installation

This plugin is available in the list of 3rd-party plugins within LMS.
You should not need to do the following but if, for some reason, it is not listed or a known recent version is not listed after a day or so of being available then
add the following repository to your Logitech Media Server:

https://paulwebster.github.io/RadioFrance/repo.xml
If that does not work (some installations of LMS do not support https) then try
http://www.dabdig.com/slimserver-rep/repo.xml - but this one might contain experimental (broken or old) versions
The 'RadioFrance' plugin should then be available for installation from the Plugin menu - after a restart of LMS.

## Usage

Once installed and LMS has been restarted you should play one of the supported radio stations.
If the plugin is working then you should see artist details appear around the time that a new track or programme starts.
You can also access the list of stations and schedules from the "My Apps" or "Radio" menu item in LMS (you can configure which one it appears under).

**FIP stations supported:**
FIP, FIP ... Rock, Jazz, Groove, Monde, Electro, Reggae, Tout Nouveau, Pop, Metal, Hip-Hop, Sacré français ! --

**France Musique stations supported:**
France Musique
Classique Easy
Opéra
La Baroque
Classique Plus
Concerts Radio France
La Jazz
La Contemporaine
Ocora Monde
Piano Zen
Evenementielle / Classique Kids / B.O. (Films)

**Mouv' stations supported:**
Mouv'
~~Mouv'Xtra~~ (Replaced by 100% Mix)
Classics, DanceHall, R'N'B, Rap US, Rap Français, 100% Mix, Kids'n Family

**Other Radio France (general) stations supported:**
France Inter
France Info
France Culture
Frnce Bleu (40+ stations)

Note: Radio France does not always provide track information in a timely manner - so if you find that sometimes no new details arrive then check on the broadcaster's site or their mobile app to see if they have the same problem.

- This plugin relies on the time on your local LMS server to be roughly correct - timezone and time - because the local time is compared with the scheduled time for each track at Radio France  
- If things are not working then enable Debug logging for this plugin via LMS/Settings/Advanced/Logging interface, repeat the problem and then check the LMS logs.  

## Version History

**0.4.9 01-Mar-2024**
- Add France Musique Piano Zen

**0.4.8 11-Oct-2023**
- Add FIP Sacre francais !
- API calls for song info changed again

**0.4.7 07-Sep-2023**
- Restore missing song info for FIP Pop

**0.4.6 25-Jul-2023**
- Data format change prevented old programmes from France Inter being shown

**0.4.5 14-Jul-2023**
- Switch artist and title around due to Radio France data format change

**0.4.4 07-Jul-2023**
- API calls for song info changed

**0.4.3 24-Sep-2022**
- Reinstate song information on France Musique (note - will not work for all tracks)
- Add FIP Metal and FIP Hip-Hop

**0.4.2 28-May-2022**
- Also replace icon for France Bleu Elsass station

**0.4.1 28-May-2022**
- Replace icons for France Bleu stations

**0.4.0 03-Jan-2022**
- Restore programme details for Now Playing on all stations

**0.3.7 28-Dec-2021**
- After changes at RadioFrance needed to adjust things to collect the programme name.
- More work needed to collect programme description and icon from a different location.
- Also - correction for FIP Groove HLS URL ( thanks @Atmis )

**0.3.6 20-Dec-2021**
- Radio France appear to have phased out the old metadata API ... so switch to new one. Only done for music stations for now. Rest to come later.

**0.3.5 09-Mar-2021**
- Add replay from schedules
- Add icon for use by Material skin

**0.2.4 23-Oct-2020**
- Add France Musique Opéra

**0.2.3 17-Jul-2020**
- Add France Musique La Baroque
- Correct eplling from English to French ... Blue to Bleu

**0.2.2 23-Jun-2020**
- Add icon for each streaming link

**0.2.1 22-Jun-2020**
- Correct stream links for 3 France Bleu stations

**0.2.0 22-Jun-2020**
- Add streaming links via LMS menu (Radio or My apps)
- Add France Bleu 40+ stations
- Add Mouv' Kids'n Family
- Metadata source changed for FIP Monde

**0.1.32 17-Jun-2020**

Add FIP Pop

**0.1.31 12-Jun-2020**

Match the HLS stream URLs faster

**0.1.30 11-Jun-2020**

Match the HLS stream URLs

**0.1.29 06-Jun-2020**

Mouv stations sometimes have 0 start/end time

**0.1.28 23-Apr-2020**

Use "album" field for programme segment name

**0.1.27 29-Sep-2019**

Inconsistent use of metadata across stations so use different way to show track names when inside a programme like Jazz A Fip

**0.1.26 22-Sep-2019**

Add another way to get programme art
Update default images for stations

**0.1.25 11-Jul-2019**

Add support for France Musique B.O.

**0.1.24 10-Jul-2019**

Add new station FIP L'été Metal

**0.1.23 09-Jul-2019**

Changed URLs for meta data and logos for some stations

**0.1.22 03-Jul-2019**

Corrected typing error that prevented ClassiquePlus track info from appearing  

**0.1.21 19-Jun-2019**

Updated default logos for some stations
Change action when joining a song in progress. Show the offset into the song if possible.  
Do not include the unused SqueezeNetwork module because results in errors if LMS running in "nomysqueeze" mode

**0.1.20 15-Feb-2019**

Add support for the new streams from Mouv' and remove the now defunct Mouv'Xtra

**0.1.19 12-Feb-2019**

Test version - start adding support for the new Mouv streams.

**0.1.18 17-Jan-2019**

Avoid warning about 2 lines being ambiguous by adding spaces around a minus sign

**0.1.17 16-Jan-2019**

Improve hiding of duration when option is set

**0.1.16 05-Nov-2018**

Support for France Inter, France Info, France Musique and France Culture (can be disabled in settings)  
FIP Autour de Reggae now supported as a distinct station rather than through FIP Evenement

**0.1.15 17-Oct-2018**

Experimental support for France Inter (can be disabled in settings)

**0.1.14 16-Oct-2018**

Show (optionally) the duration of the song (thanks to philippe_44 for the key two lines of code). If you enable/disable this then wait for one track before it takes effect  
Add configurable stream delay parameter - default is 2 seconds. Indicates how far behind real time the stream is - making this accurate can help with timely changes of song info, especially visible if track duration is shown

**0.1.13 04-May-2018**

Data sources for the regional FIP stations stopped working in mid-March 2018 so use alternate (same as main FIP)

**0.1.12 02-May-2018**

Radio France now sometimes includes an empty artist name (performers) rather than omitting the field - so use alternate field (authors) in that case

**0.1.11 28-Feb-2018**

Add warning if Perl SSL support missing because https sometimes required to collect metadata

**0.1.10 17-Jun-2017**

Add FIP Autour de l'Electro  
Change alternate fetch mechanism to always fetch if available and remove setting that controlled it  
Change some station logos to higher definition

**0.1.9 06-Mar-2017**

Add ability to show record label (publisher) and year at end of album name

**0.1.8 22-Feb-2017**

Modify the alternate fetch mechanism to get from both sources to improve chances of getting cover art

**0.1.7 07-Feb-2017**

Add alternative URL for Mouv'

**0.1.6 07-Feb-2017**

Add radio station Mouv' Xtra

Add setting to allow programme image to replace station logo  
 - note will not have any effect for many stations because many do not provide the data
 
**0.1.5 06-Feb-2017**

Add alternate URLs for FIP stations and make them (all in one) selectable  
Makes more tracks have images but updates might not be as timely
