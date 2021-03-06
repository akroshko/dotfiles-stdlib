#! perl

# Copyright (C) 2018-2019, Andrew Kroshko, all rights reserved.
# Copyright (C) 2003-2015 Marc Alexander Lehmann and others
#
# Author: Andrew Kroshko
# Maintainer: Andrew Kroshko <akroshko.public+devel@gmail.com>
# Created: Mon Feb 19, 2018
# Version: 20191209
# URL: https://github.com/akroshko/cic-dotfiles
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or (at
# your option) any later version.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
# General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see http://www.gnu.org/licenses/.

# this extension implements scrollback buffer search

#:META:X_RESOURCE:%:string:activation hotkey keysym

=head1 NAME

searchable-scrollback<hotkey> - incremental scrollback search (enabled by default)

=head1 DESCRIPTION

Adds regex search functionality to the scrollback buffer, triggered
by a hotkey (default: C<M-r>). While in search mode, normal terminal
input/output is suspended and a regex is displayed at the bottom of the
screen.

Inputting characters appends them to the regex and continues incremental
search. C<BackSpace> removes a character from the regex, C<Up> and C<Down>
search upwards/downwards in the scrollback buffer, C<End> jumps to the
bottom. C<Escape> leaves search mode and returns to the point where search
was started, while C<Enter> or C<Return> stay at the current position and
additionally stores the first match in the current line into the primary
selection if the C<Shift> modifier is active.

The regex defaults to "(?i)", resulting in a case-insensitive search. To
get a case-sensitive search you can delete this prefix using C<BackSpace>
or simply use an uppercase character which removes the "(?i)" prefix.

See L<perlre> for more info about perl regular expression syntax.

=cut

sub on_init {
   my ($self) = @_;

   my $hotkey = $self->{argv}[0]
                || $self->x_resource ("%")
                || "Mod3-r";

   $self->parse_keysym ($hotkey, "perl:searchable-scrollback:start")
      or warn "unable to register '$hotkey' as scrollback search start hotkey\n";

   ()
}

sub on_user_command {
   my ($self, $cmd) = @_;

   $cmd eq "searchable-scrollback:start"
      and $self->enter;

   ()
}

sub msg {
   my ($self, $msg) = @_;

   $self->{overlay} = $self->overlay (0, -1, $self->ncol, 1, urxvt::OVERLAY_RSTYLE, 0);
   $self->{overlay}->set (0, 0, $self->special_encode ($msg));
}

sub enter {
   my ($self) = @_;

   return if $self->{overlay};

   $self->{view_start} = $self->view_start;
   $self->{pty_ev_events} = $self->pty_ev_events (urxvt::EV_NONE);
   $self->{row} = $self->nrow - 1;
   $self->{search} = "(?i)";

   $self->enable (
      key_press     => \&key_press,
      tt_write      => \&tt_write,
      refresh_begin => \&refresh,
      refresh_end   => \&refresh,
   );

   $self->{manpage_overlay} = $self->overlay (0, -2, $self->ncol, 1, urxvt::OVERLAY_RSTYLE, 0);
   $self->{manpage_overlay}->set (0, 0, "scrollback search, see the ${urxvt::RXVTNAME}perl manpage for details");

   $self->idle;
}

sub leave {
   my ($self) = @_;

   $self->disable ("key_press", "tt_write", "refresh_begin", "refresh_end");
   $self->pty_ev_events ($self->{pty_ev_events});

   delete $self->{manpage_overlay};
   delete $self->{overlay};
   delete $self->{history};
   delete $self->{search};
}

sub idle {
   my ($self) = @_;

   $self->msg ("(escape cancels) /$self->{search}█");
}

sub search {
   my ($self, $dir) = @_;

   delete $self->{found};
   my $row = $self->{row};

   my $search = $self->special_encode ($self->{search});

   no re 'eval'; # just to be sure
   if (my $re = eval { qr/$search/ }) {
      while ($self->nrow > $row && $row >= $self->top_row) {
         my $line = $self->line ($row)
            or last;

         my $text = $line->t;
         if ($text =~ /$re/g) {
            do {
               push @{ $self->{found} }, [$line->coord_of ($-[0]), $line->coord_of ($+[0])];
            } while $text =~ /$re/g;

            $self->{row} = $row;
            $self->view_start (List::Util::min 0, $row - ($self->nrow >> 1));
            $self->want_refresh;
            last;
         }

         $row = $dir < 0 ? $line->beg - 1 : $line->end + 1;
      }
   }

   $self->scr_bell unless $self->{found};
}

sub refresh {
   my ($self) = @_;

   return unless $self->{found};

   my $xor = urxvt::RS_RVid | urxvt::RS_Blink;
   for (@{ $self->{found} }) {
      $self->scr_xor_span (@$_, $xor);
      $xor = urxvt::RS_RVid;
   }

   ()
}

# TODO: how to alt to keysyms
sub key_press {
   my ($self, $event, $keysym, $string) =  @_;

   delete $self->{manpage_overlay};

   # r is keysym 0x72
   # f is keysym 0x???

   if ($keysym == 0xff0d || $keysym == 0xff8d) { # enter
      if ($self->{found} && $event->{state} & urxvt::ShiftMask) {
         my ($br, $bc, $er, $ec) = @{ $self->{found}[0] };
         $self->selection_beg ($br, $bc);
         $self->selection_end ($er, $ec);
         $self->selection_make ($event->{time});
      }
      $self->leave;
   } elsif ($keysym == 0xff1b) { # escape
      $self->view_start ($self->{view_start});
      $self->leave;
   } elsif ($keysym == 0xff57) { # end
      $self->{row} = $self->nrow - 1;
      $self->view_start (0);
   } elsif ($keysym == 0xff52) { # up
      $self->{row}-- if $self->{row} > $self->top_row;
      $self->search (-1);
   } elsif ($keysym == 0xff54) { # down
      $self->{row}++ if $self->{row} < $self->nrow;
      $self->search (+1);
   } elsif ($keysym == 0xff08) { # backspace
      substr $self->{search}, -1, 1, "";
      $self->search;
      $self->idle;
   } elsif ($keysym == 0x72 && $event->{state} & urxvt::Mod3Mask) { # hyper-r
      # same as up key
      # TODO: combine?
      $self->{row}-- if $self->{row} > $self->top_row;
      $self->search (-1);
   } elsif ($keysym == 0x66 && $event->{state} & urxvt::Mod3Mask) { # hyper-f
      # same as down key
      # TODO: combine?
      $self->{row}++ if $self->{row} < $self->nrow;
      $self->search (+1);
   } elsif ($string !~ /[\x00-\x1f\x80-\xaf]/) {
      return; # pass to tt_write
   }

   1
}

sub tt_write {
   my ($self, $data) = @_;

   $self->{search} .= $self->locale_decode ($data);

   $self->{search} =~ s/^\(\?i\)//
      if $self->{search} =~ /^\(.*[[:upper:]]/;

   $self->search (-1);
   $self->idle;

   1
}
