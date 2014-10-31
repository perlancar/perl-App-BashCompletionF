package App::BashCompletionF;

# DATE
# VERSION

use 5.010001;
use strict;
use warnings;

use File::Slurp::Tiny qw();
use List::Util qw(first);
use Perinci::Object;
use Perinci::Sub::Util qw(err);
use Text::Fragment qw();

our %SPEC;

$SPEC{':package'} = {
    v => 1.1,
    summary => 'Manipulate bash-completion-f file which contains completion scripts',
};

sub _f_path {
    if ($>) {
        "$ENV{HOME}/.bash-completion-f";
    } else {
        "/etc/bash-completion-f";
    }
}

sub _read_parse_f {
    my $path = shift // _f_path();
    my $text = (-f $path) ? File::Slurp::Tiny::read_file($path) : "";
    my $listres = Text::Fragment::list_fragments(text=>$text);
    return $listres if $listres->[0] != 200;
    [200,"OK",{content=>$text, parsed=>$listres->[2]}];
}

sub _write_f {
    my $path = shift // _f_path();
    my $content = shift;
    File::Slurp::Tiny::write_file($path, $content);
    [200];
}

my %arg_file = (file => {
    summary => 'Use alternate location for the bash-completion-f file',
    schema => 'str*',
    description => <<'_',

By default, the `complete` scripts are put in a file either in
`/etc/bash-completion-f` (if running as root) or `~/.bash-completion-f` (if
running as normal user). This option sets another location.

_
    cmdline_aliases => {f=>{}},
});

my %arg_id = (id => {
    summary => 'Entry ID, for marker (usually command name)',
    schema  => ['str*', {match => $Text::Fragment::re_id}],
    req     => 1,
    pos     => 0,
});

my %arg_program = (program => {
    summary => 'Program name(s) to add',
    schema => ['array*' => {
        of => ['str*', {match=>$Text::Fragment::re_id}], # XXX strip dir first before matching
        min_len => 1,
    }],
    req => 1,
    pos => 0,
    greedy => 1,
});

my %arg_dir = (dir => {
    summary => 'Dir and file name(s) to search',
    schema => ['array*' => {
        of => ['str*'], # XXX strip dir first before matching
        min_len => 1,
    }],
    pos => 0,
    greedy => 1,
});

$SPEC{add_entry} = {
    v => 1.1,
    summary => 'Add a completion entry',
    args => {
        %arg_id,
        content => {
            summary => 'Entry content (the actual "complete ..." bash command)',
            schema => 'str*',
            req => 1,
            pos => 1,
        },
        %arg_file,
    },
};
sub add_entry {
    my %args = @_;

    my $id = $args{id};
    my $content = $args{content};

    # XXX schema (coz when we're not using P::C there's no schema validation)
    $id =~ $Text::Fragment::re_id or
        return [400, "Invalid syntax for 'id', please use word only"];

    my $res = _read_parse_f($args{file});
    return err("Can't read entries", $res) if $res->[0] != 200;

    # avoid duplicate
    return [409, "Duplicate id '$id'"]
        if first {$_->{id} eq $id} @{$res->[2]{parsed}};

    # avoid clash with fragment marker
    $content =~ s/^(# (?:BEGIN|END) FRAGMENT)/ $1/gm;

    my $insres = Text::Fragment::insert_fragment(
        text=>$res->[2]{content}, id=>$id, payload=>$content);
    return err("Can't add", $insres) if $insres->[0] != 200;

    my $writeres = _write_f($args{file}, $insres->[2]{text});
    return err("Can't write", $writeres) if $writeres->[0] != 200;

    [200];
}

$SPEC{add_entries_pc} = {
    v => 1.1,
    summary => 'Add completion entries for Perinci::CmdLine-based CLI programs',
    description => <<'_',

This is a shortcut for `add_entry`. Doing:

    % bash-completion-f add-pc foo bar baz

will be the same as:

    % bash-completion-f add --id foo 'complete -C foo foo'
    % bash-completion-f add --id bar 'complete -C bar bar'
    % bash-completion-f add --id baz 'complete -C baz baz'

_
    args => {
        %arg_program,
        %arg_file,
    },
};
sub add_entries_pc {
    my %args = @_;

    _add_pc({progs=>delete($args{program})}, %args);
}

$SPEC{remove_entry} = {
    v => 1.1,
    summary => '',
    args => {
        %arg_id,
        %arg_file,
    },
};
sub remove_entry {
    my %args = @_;

    my $id = $args{id};

    # XXX schema (coz when we're not using P::C there's no schema validation)
    $id =~ $Text::Fragment::re_id or
        return [400, "Invalid syntax for 'id', please use word only"];

    my $res = _read_parse_f($args{file});
    return err("Can't read entries", $res) if $res->[0] != 200;

    my $delres = Text::Fragment::delete_fragment(
        text=>$res->[2]{content}, id=>$id);
    return err("Can't delete", $delres) if $delres->[0] !~ /200|304/;

    if ($delres->[0] == 200) {
        my $writeres = _write_f($args{file}, $delres->[2]{text});
        return err("Can't write", $writeres) if $writeres->[0] != 200;
    }

    [200];
}

$SPEC{list_entries} = {
    v => 1.1,
    summary => '',
    args => {
        %arg_file,
        detail => {
            schema => 'bool',
        },
    },
};
sub list_entries {
    my %args = @_;

    my $res = _read_parse_f($args{file} // _f_path());
    return $res if $res->[0] != 200;

    my @res;
    for (@{ $res->[2]{parsed} }) {
        if ($args{detail}) {
            push @res, {id=>$_->{id}, payload=>$_->{payload}};
        } else {
            push @res, $_->{id};
        }
    }

    [200, "OK", \@res];
}

sub _parse_entry {
    require Parse::CommandLine;

    my $payload = shift;
    $payload =~ /^(complete\s.+)/m # XXX support multiline 'complete' command
        or return [500, "Can't find 'complete' command"];

    my @argv = Parse::CommandLine::parse_command_line($1)
        or return [500, "Can't parse 'complete' command"];

    # strip options that take argument. XXX very rudimentary, should be more
    # proper (e.g. handle bundling).
    my $i = 0;
    while ($i < @argv) {
        if ($argv[$i] =~ /\A-[oAGWFCXPS]/) {
            splice(@argv, $i, 2);
            next;
        }
        $i++;
    }
    shift @argv; # strip 'complete' itself
    # XXX we just assume the names are at the end, should've stripped options
    # more properly
    my @names;
    for (reverse @argv) {
        last if /\A-/;
        push @names, $_;
    }

    [200, "OK", {names=>\@names}];
}

$SPEC{clean_entries} = {
    v => 1.1,
    summary => 'Delete entries for commands that are not in PATH',
    description => <<'_',

Sometimes when a program gets uninstalled, it still leaves completion entry.
This subcommand will search all entries for commands that are no longer found in
PATH and remove them.

_
    args => {
        %arg_file,
    },
};
sub clean_entries {
    require File::Which;

    my %args = @_;

    my $res = _read_parse_f($args{file});
    return err("Can't read entries", $res) if $res->[0] != 200;

    my $content = $res->[2]{content};
    my $deleted;
    for my $entry (@{ $res->[2]{parsed} }) {
        my $parseres = _parse_entry($entry->{payload});
        unless ($parseres->[0] == 200) {
            warn "Can't parse 'complete' command for entry '$entry->{id}': ".
                "$parseres->[1], skipped\n";
            next;
        }
        # remove if none of the names in complete command are in PATH
        my $found;
        for my $name (@{ $parseres->[2]{names} }) {
            if (File::Which::which($name)) {
                $found++; last;
            }
        }
        next if $found;
        say join(", ", @{$parseres->[2]{names}})." not found in PATH, ".
            "removing entry $entry->{id}";
        my $delres = Text::Fragment::delete_fragment(
            text=>$content, id=>$entry->{id});
        return err("Can't delete entry $entry->{id}", $delres)
            if $delres->[0] != 200;
        $deleted++;
        $content = $delres->[2]{text};
    }

    if ($deleted) {
        my $writeres = _write_f($args{file}, $content);
        return err("Can't write", $writeres) if $writeres->[0] != 200;
    }

    [200];
}

sub _add_pc {
    my $opts = shift;

    my %args = @_;

    my $res = _read_parse_f($args{file});
    return err("Can't read entries", $res) if $res->[0] != 200;

    my $content = $res->[2]{content};

    # collect all the names mentioned
    my %names;
    for my $entry (@{ $res->[2]{parsed} }) {
        my $parseres = _parse_entry($entry->{payload});
        unless ($parseres->[0] == 200) {
            warn "Can't parse 'complete' command for entry '$entry->{id}': ".
                "$parseres->[1], skipped\n";
            next;
        }
        $names{$_}++ for @{ $parseres->[2]{names} };
    }

    my $added;
    my @progs;

    if ($opts->{dirs}) {
        for my $dir (@{ $opts->{dirs} }) {
            opendir my($dh), $dir or next;
            #say "D:searching $dir";
            for my $prog (readdir $dh) {
                (-f "$dir/$prog") && (-x _) or next;
                $names{$prog} and next;

                # skip non-scripts
                open my($fh), "<", "$dir/$prog" or next;
                read $fh, my($buf), 2; $buf eq '#!' or next;
                # skip non perl
                my $shebang = <$fh>; $shebang =~ /perl/ or next;
                my $found;
                # skip unless we found something like 'use Perinci::CmdLine'
                while (<$fh>) {
                    if (/^\s*(use|require)\s+Perinci::CmdLine(|::Any|::Lite)/) {
                        $found++; last;
                    }
                }
                next unless $found;

                $prog =~ $Text::Fragment::re_id or next;

                #say "D:$dir/$prog is a Perinci::CmdLine program";
                push @progs, $prog;
                $added++;
                $names{$prog}++;
            }
        }
    } elsif ($opts->{progs}) {
        for my $prog (@{ $opts->{progs} }) {
            $prog =~ s!.+/!!;
            $names{$prog} and next;
            push @progs, $prog;
            $added++;
            $names{$prog}++;
        }
    } else {
        die "BUG: no progs or dirs given";
    }

    my $envres = envresmulti();
    for my $prog (@progs) {
        my $insres = Text::Fragment::insert_fragment(
            text=>$content, id=>$prog,
            payload=>"complete -C '$prog' '$prog'");
        $envres->add_result($insres->[0], $insres->[1], {item_id=>$prog});
        next unless $insres->[0] == 200;
        $content = $insres->[2]{text};
    }

    if ($added) {
        my $writeres = _write_f($args{file}, $content);
        return err("Can't write", $writeres) if $writeres->[0] != 200;
    }

    $envres->as_struct;
}

$SPEC{add_all_pc} = {
    v => 1.1,
    summary => 'Find all scripts that use Perinci::CmdLine in specified dirs (or PATH)' .
        ' and add completion entries for them',
    description => <<'_',
_
    args => {
        %arg_file,
        %arg_dir,
    },
};
sub add_all_pc {
    my %args = @_;
    _add_pc({dirs => delete($args{dirs}) // [split /:/, $ENV{PATH}]}, %args);
}

1;
# ABSTRACT: Backend for bash-completion-f script

