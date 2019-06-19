---
layout: page
title: RadioFrance - Slimerver/LMS PlugIn to get song information from Radio France stations
---

Slimerver/LMS PlugIn to get song information from Radio France stations
=========================================

Display artist, track, cover and, optionally, album name, label and year for:
* FIP (http://www.fipradio.fr) stations (including web stations such as Autour du Jazz)
* France Musique (http://www.francemusique.fr) web stations (such as Ocora and Classique Plus)
* Mouv' (http://www.mouv.fr)
Display programme name and synopsis (when available) for:
* France Inter, France Info, France Musique, France Culture

This software is licensed under the GPL.

## Requirements

This plugin requires Logitech Media Server v7.4.0 or greater.

## Installation

If not already visible in LMS then add the following repository to your Logitech Media Server:

https://paulwebster.github.io/RadioFrance/repo.xml
If that does not work (some installations of LMS do not support https) then try
http://www.dabdig.com/slimserver-rep/repo.xml - but this one might contain experimental (broken) versions

The 'RadioFrance' plugin should then be available for installation from the Plugin menu - probably after a restart of LMS.

## Usage

Once installed and LMS has been restarted you should play one of the supported radio stations.
If the plugin is working then you should see artist details appear around the time that a new track starts.

**FIP stations supported:**
FIP (including regional variants while they last), FIP autour ... du Rock, du Jazz, du Groove, du Monde, de l'Electro, de Reggae plus Tout Nouveau.

**France Musique stations supported:**
Classique Easy
Classique Plus
Concerts Radio France
La Jazz
La Contemporaine
Ocora Monde
Evenementielle / Classique Kids

**Mouv' stations supported:**
Mouv'
~~Mouv'Xtra~~ (Replaced by 100% Mix)
Classics, DanceHall, R'N'B, Rap US, Rap Français, 100% Mix

**Other Radio France (general) stations supported:**
France Inter
France Info
France Musique
France Culture

Note: Radio France does not always provide track information in a timely manner - so if you find that sometimes no new details arrive then check on the FIP site or their mobile app to see if they have the same problem.

- This plugin relies on the time on your local LMS server to be roughly correct - timezone and time - because the local time is compared with the scheduled time for each track at Radio France  
- If things are not working then enable Debug logging for this plugin via LMS/Settings/Advanced/Logging interface, repeat the problem and then check the LMS logs.  

## Version History
65d3199a553ee01f6f78abf166a36e9b30e9b6c8
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

