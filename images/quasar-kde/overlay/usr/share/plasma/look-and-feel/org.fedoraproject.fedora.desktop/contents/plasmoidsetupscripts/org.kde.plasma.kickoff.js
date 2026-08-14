/*
   Quasar modification (2026-08-13, spec 2026-08-13-quasar-kde-implementation.md
   §2): overrides the icon this plasmoid-setup script assigns to a freshly
   created Kickoff applet, from Fedora's "start-here-kde-fedora" to "quasar"
   (see /usr/share/icons/hicolor/{scalable,256x256}/apps/quasar.*). This is
   the file Fedora's org.fedoraproject.fedora.desktop look-and-feel package
   actually runs on Kickoff-applet creation -- NOT
   /usr/share/plasma/shells/org.kde.plasma.desktop/contents/layout.js, which
   does not exist in this Plasma build (Plasma 6.7.4, kde-settings-43.101,
   Fedora 43). Only applies on a fresh $HOME (no
   plasma-org.kde.plasma.desktop-appletsrc yet); a user who changes the icon
   keeps their change on relaunch, per the persistence model.

   Taken from and replaces the stock 00-start-here-kde-fedora.js verbatim
   below the header; original license/attribution preserved as required.

   00-start-here-kde-fedora.js - Set launcher icon to start-here-kde-fedora
   Copyright (C) 2010 Kevin Kofler <kevin.kofler@chello.at>
   Copyright (C) 2010 Rex Dieter <rdieter@fedoraproject.org>

   This program is free software: you can redistribute it and/or modify
   it under the terms of the GNU General Public License as published by
   the Free Software Foundation, either version 2 of the License, or
   (at your option) any later version.

   This program is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program.  If not, see <http://www.gnu.org/licenses/>.

   Portions lifted from 01-kubuntu-10.04.js:
   Harald Sitter, apachelogger@ubuntu.com 2010-04-02
   Jonathan Riddell, jriddell@ubuntu.com 2010-02-18
   Copyright Canonical Ltd, may be copied under the GNU GPL 2 or later
*/

if ( applet.readConfig("icon", "start-here-kde") == "start-here-kde" ) {
  applet.currentConfigGroup = ["General"]
  applet.writeConfig("icon", "quasar");
}
