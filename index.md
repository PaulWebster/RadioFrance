---
layout: page
title: RadioFrance - Slimerver/LMS PlugIn to get song information from Radio France stations
---

Slimerver/LMS PlugIn to get song information from Radio France stations
=========================================

Display artist, track, cover and, optionally, album name, label and year for:
* FIP (http://www.fipradio.fr) stations (including web stations such as Jazz)
* France Musique (http://www.francemusique.fr) web stations (such as Ocora and Classique Plus)
* Mouv' (http://www.mouv.fr) (including web stations such as Classics)
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
FIP (including regional variants while they last), FIP ... Rock, Jazz, Groove, Monde, Electro, Reggae, Tout Nouveau plus l'été Metal.

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

