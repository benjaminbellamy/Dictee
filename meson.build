# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Benjamin Bellamy <bbellamy@linagora.com>

project('dictee', ['vala', 'c'],
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 1.1',
  default_options: ['warning_level=1'],
)

gtk     = dependency('gtk4',          version: '>= 4.10')
adwaita = dependency('libadwaita-1',  version: '>= 1.4')
gst     = dependency('gstreamer-1.0', version: '>= 1.20')
glib    = dependency('glib-2.0')
gobject = dependency('gobject-2.0')
gio     = dependency('gio-2.0')
m_dep   = meson.get_compiler('c').find_library('m', required: false)

# Required so that Vala's `_()` translation macro (from gi18n-lib.h) compiles.
# We do not ship .mo files; gettext falls back to the source string.
add_project_arguments('-DGETTEXT_PACKAGE="dictee"', language: 'c')

subdir('src')
subdir('data')

gnome = import('gnome')
gnome.post_install(
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)
