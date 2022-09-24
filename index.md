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
FIP (including regional variants while they last), FIP ... Rock, Jazz, Groove, Monde, Electro, Reggae, Tout Nouveau, Pop, Metal, Hip-Hop --

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
Evenementielle / Classique Kids / B.O.

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
