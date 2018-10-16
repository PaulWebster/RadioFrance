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
This software is licensed under the GPL.

## Requirements

This plugin requires Logitech Media Server v7.4.0 or greater.

## Installation

Add the following repository to your Logitech Media Server:

https://paulwebster.github.io/RadioFrance/repo.xml
If that does not work (some installations of LMS do not support https) then try
http://www.dabdig.com/slimserver-rep/repo.xml - but this one might contain experimental (broken) versions

The 'RadioFrance' plugin should then be available for installation from the Plugin menu - probably after a restart of LMS.

## Usage

Once installed and LMS has been restarted you should play one of the supported radio stations.
If the plugin is working then you should see artist details appear around the time that a new track starts.

**FIP stations supported:**
FIP (including regional variants while they last), FIP autour ... du Rock, du Jazz, du Groove, du Monde, de l'Electro plus Tout Nouveau and Evenement (Reggae at time of writing).

**France Musique stations supported:**
Classique Easy
Classique Plus
Concerts Radio France
La Jazz
La Contemporaine
Ocora Monde
Evenementielle / Classique Kids
but not France Musique itself as they only make the programme name available and that comes from Tunein anyway

**Mouv' stations supported:**
Mouv'
Mouv'Xtra
	
Note: Radio France does not always provide track information in a timely manner - so if you find that sometimes no new details arrive then check on the FIP site or teir mobile app to see if they have the same problem.

- This plugin relies on the time on your local LMS server to be roughly correct - timezone and time - because the local time is compared with the scheduled time for each track at Radio France  
- If things are not working then enable Debug logging for this plugin via LMS/Settings/Advanced/Logging interface, repeat the problem and then check the LMS logs.  

## Version History
**0.1.14 16-Oct-2018

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

