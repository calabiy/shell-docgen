use strict;
use warnings;
use utf8;
use File::Basename;
use Encode qw(decode encode);


binmode(STDOUT, ':utf8');
binmode(STDERR, ':utf8');


sub main {
    my $script_file = shift @ARGV;
    
    unless ($script_file) {
        print "Использование: $0 <script.sh>\n";
        print "Пример: $0 backup.sh\n";
        exit 1;
    }
    
    unless (-f $script_file) {
        die "Ошибка: файл '$script_file' не найден!\n";
    }
    
    my $analyzer = ShellScriptAnalyzer->new($script_file);
    my $doc = $analyzer->analyze();
    
    # сохраняем документацию
    my $output_file = basename($script_file, '.sh') . '_documentation.md';
    open my $fh, '>:utf8', $output_file or die "Не могу создать файл $output_file: $!";
    print $fh $doc;
    close $fh;
    
    print "Документация сохранена в: $output_file\n";
}

# класс анализа shell скриптов
package ShellScriptAnalyzer;

sub new {
    my ($class, $file) = @_;
    my $self = {
        file => $file,
        lines => [],
        variables => {},
        functions => {},
        dependencies => [],
        sections => [],
        description => '',
        usage => ''
    };
    
    bless $self, $class;
    $self->_read_file();
    return $self;
}

sub _read_file {
    my $self = shift;
    
    open my $fh, '<:utf8', $self->{file} or die "Не могу открыть файл $self->{file}: $!";
    @{$self->{lines}} = <$fh>;
    close $fh;
    
    # убираем переносы строк
    chomp @{$self->{lines}};
}

sub analyze {
    my $self = shift;
    
    $self->_parse_header();
    $self->_find_variables();
    $self->_find_functions();
    $self->_find_dependencies();
    $self->_analyze_sections();
    
    return $self->_generate_documentation();
}

sub _parse_header {
    my $self = shift;
    my $in_header = 1;
    
    for my $line (@{$self->{lines}}) {
        # пропуск shebang
        next if $line =~ /^#!/;
        
        # если строка начинается с #, это комментарий
        if ($line =~ /^#\s*(.*)/) {
            my $comment = $1;
            
            # ищем описание и использование
            if ($comment =~ /^(Описание|Description):\s*(.+)/i) {
                $self->{description} = $2;
            } elsif ($comment =~ /^(Использование|Usage):\s*(.+)/i) {
                $self->{usage} = $2;
            } elsif ($comment && !$self->{description}) {
                $self->{description} = $comment;
            }
        } elsif ($line =~ /\S/) {
            # если не коммент, то заканчиваем парсинг заголовка
            last;
        }
    }
}

sub _find_variables {
    my $self = shift;
    
    for my $line (@{$self->{lines}}) {
        # поиск объявлений переменных
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.+)/) {
            my ($var, $value) = ($1, $2);
            $value =~ s/^["']|["']$//g;  # убираем кавычки
            $self->{variables}{$var} = $value;
        }
        
        # поиск read команд
        if ($line =~ /read\s+(?:-p\s*["']([^"']+)["']\s+)?([A-Za-z_][A-Za-z0-9_]*)/) {
            my $prompt = $1 || "Ввод значения";
            my $var = $2;
            $self->{variables}{$var} = "Пользовательский ввод: $prompt";
        }
    }
}

sub _find_functions {
    my $self = shift;
    
    for my $i (0..$#{$self->{lines}}) {
        my $line = $self->{lines}[$i];
        
        # поиск функций
        if ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*\(\s*\)\s*{?/ || 
            $line =~ /^function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(?/) {
            
            my $func_name = $1;
            my $description = "";
            
            # ищем комментарий перед функцией
            if ($i > 0 && $self->{lines}[$i-1] =~ /^#\s*(.+)/) {
                $description = $1;
            }
            
            $self->{functions}{$func_name} = $description || "Функция $func_name";
        }
    }
}

sub _find_dependencies {
    my $self = shift;
    my %deps;
    
    for my $line (@{$self->{lines}}) {
        if ($line =~ /\b(curl|wget|git|docker|kubectl|aws|gcloud|ssh|scp|rsync|tar|zip|unzip|grep|awk|sed|sort|uniq|head|tail|cut|tr|find|xargs|jq|yq)\b/) {
            $deps{$1} = 1;
        }
        
        if ($line =~ /(?:source|\.|include)\s+([^\s]+)/) {
            $deps{"файл: $1"} = 1;
        }
    }
    
    @{$self->{dependencies}} = sort keys %deps;
}

sub _analyze_sections {
    my $self = shift;
    my @sections;
    my $current_section = {
        name => "Основной код",
        description => "",
        commands => [],
        line_start => 1
    };
    
    for my $i (0..$#{$self->{lines}}) {
        my $line = $self->{lines}[$i];
        
        # пропуск коммент заголовка
        next if $line =~ /^#!/;
        
        # определяем секции по комментариям
        if ($line =~ /^#\s*={3,}/) {
            # разделитель секций
            push @sections, $current_section if @{$current_section->{commands}};
            $current_section = {
                name => "Секция",
                description => "",
                commands => [],
                line_start => $i + 1
            };
        } elsif ($line =~ /^#\s*(.+)/) {
            my $comment = $1;
            if ($comment !~ /^(Описание|Description|Использование|Usage):/i) {
                $current_section->{description} = $comment if !$current_section->{description};
            }
        } elsif ($line =~ /\S/) {
            my $cmd_info = $self->_analyze_command($line);
            push @{$current_section->{commands}}, $cmd_info if $cmd_info;
        }
    }
    
    push @sections, $current_section if @{$current_section->{commands}};
    @{$self->{sections}} = @sections;
}

sub _analyze_command {
    my ($self, $line) = @_;
    
    # убираем лишние пробелы
    $line =~ s/^\s+|\s+$//g;
    return undef if !$line;
    
    my $info = {
        original => $line,
        type => 'command',
        description => '',
        explanation => ''
    };
    
    # определяем тип команды и добавляем обяснение
    if ($line =~ /^if\s+/) {
        $info->{type} = 'condition';
        $info->{description} = 'Условная конструкция';
        $info->{explanation} = $self->_explain_condition($line);
    } elsif ($line =~ /^for\s+/) {
        $info->{type} = 'loop';
        $info->{description} = 'Цикл';
        $info->{explanation} = $self->_explain_loop($line);
    } elsif ($line =~ /^while\s+/) {
        $info->{type} = 'loop';
        $info->{description} = 'Цикл while';
        $info->{explanation} = $self->_explain_while($line);
    } elsif ($line =~ /curl\s+/) {
        $info->{type} = 'network';
        $info->{description} = 'HTTP-запрос';
        $info->{explanation} = $self->_explain_curl($line);
    } elsif ($line =~ /grep\s+/) {
        $info->{type} = 'filter';
        $info->{description} = 'Поиск в тексте';
        $info->{explanation} = $self->_explain_grep($line);
    } elsif ($line =~ /awk\s+/) {
        $info->{type} = 'processing';
        $info->{description} = 'Обработка текста';
        $info->{explanation} = $self->_explain_awk($line);
    } elsif ($line =~ /sed\s+/) {
        $info->{type} = 'processing';
        $info->{description} = 'Замена текста';
        $info->{explanation} = $self->_explain_sed($line);
    } elsif ($line =~ /^([A-Za-z_][A-Za-z0-9_]*)\s*=/) {
        $info->{type} = 'variable';
        $info->{description} = 'Присвоение переменной';
        $info->{explanation} = "Устанавливает значение переменной";
    } elsif ($line =~ /^echo\s+/) {
        $info->{type} = 'output';
        $info->{description} = 'Вывод текста';
        $info->{explanation} = 'Выводит текст на экран';
    } else {
        $info->{description} = 'Выполнение команды';
        $info->{explanation} = $self->_explain_generic_command($line);
    }
    
    return $info;
}

sub _explain_condition {
    my ($self, $line) = @_;
    
    if ($line =~ /if\s+\[\s*(.+?)\s*\]/) {
        my $condition = $1;
        return "Проверяет условие: $condition";
    }
    return "Условная конструкция";
}

sub _explain_loop {
    my ($self, $line) = @_;
    
    if ($line =~ /for\s+(\w+)\s+in\s+(.+)/) {
        my ($var, $items) = ($1, $2);
        return "Цикл по элементам: переменная '$var' принимает значения из '$items'";
    }
    return "Цикл for";
}

sub _explain_while {
    my ($self, $line) = @_;
    
    if ($line =~ /while\s+(.+)/) {
        my $condition = $1;
        return "Цикл while: выполняется пока '$condition' истинно";
    }
    return "Цикл while";
}

sub _explain_curl {
    my ($self, $line) = @_;
    
    my $explanation = "HTTP-запрос";
    
    if ($line =~ /-X\s+(\w+)/) {
        $explanation .= " методом $1";
    }
    if ($line =~ /-H\s+["']([^"']+)["']/) {
        $explanation .= ", с заголовком '$1'";
    }
    if ($line =~ /-d\s+["']([^"']+)["']/) {
        $explanation .= ", с данными";
    }
    if ($line =~ /https?:\/\/([^\s]+)/) {
        $explanation .= " к $1";
    }
    
    return $explanation;
}

sub _explain_grep {
    my ($self, $line) = @_;
    
    if ($line =~ /grep\s+(?:-\w+\s+)?["']?([^"'\s]+)["']?/) {
        my $pattern = $1;
        return "Ищет строки содержащие '$pattern'";
    }
    return "Поиск в тексте";
}

sub _explain_awk {
    my ($self, $line) = @_;
    
    if ($line =~ /awk\s+["']([^"']+)["']/) {
        my $script = $1;
        return "Обрабатывает текст: $script";
    }
    return "Обработка текста с помощью AWK";
}

sub _explain_sed {
    my ($self, $line) = @_;
    
    if ($line =~ /sed\s+["']s\/([^\/]+)\/([^\/]*)\/[^"']*["']/) {
        my ($from, $to) = ($1, $2);
        return "Заменяет '$from' на '$to'";
    }
    return "Замена текста с помощью sed";
}

sub _explain_generic_command {
    my ($self, $line) = @_;
    
    my ($cmd) = $line =~ /^(\w+)/;
    return "Выполняет команду '$cmd'" if $cmd;
    return "Выполняет команду";
}

sub _generate_documentation {
    my $self = shift;
    
    my $doc = '';
    my $script_name = basename($self->{file});
    
    $doc .= "# Документация для $script_name\n\n";
    
    if ($self->{description}) {
        $doc .= "##Описание\n\n";
        $doc .= "$self->{description}\n\n";
    }
    
    if ($self->{usage}) {
        $doc .= "##Использование\n\n";
        $doc .= "```bash\n$self->{usage}\n```\n\n";
    } else {
        $doc .= "##Использование\n\n";
        $doc .= "```bash\n./$script_name\n```\n\n";
    }
    
    if (@{$self->{dependencies}}) {
        $doc .= "##Зависимости\n\n";
        $doc .= "Скрипт требует следующие программы/файлы:\n\n";
        for my $dep (@{$self->{dependencies}}) {
            $doc .= "- `$dep`\n";
        }
        $doc .= "\n";
    }

    if (%{$self->{variables}}) {
        $doc .= "##Переменные\n\n";
        for my $var (sort keys %{$self->{variables}}) {
            my $value = $self->{variables}{$var};
            $doc .= "- **$var**: $value\n";
        }
        $doc .= "\n";
    }

    if (%{$self->{functions}}) {
        $doc .= "##Функции\n\n";
        for my $func (sort keys %{$self->{functions}}) {
            my $desc = $self->{functions}{$func};
            $doc .= "### $func()\n\n";
            $doc .= "$desc\n\n";
        }
    }
    
    if (@{$self->{sections}}) {
        $doc .= "##Анализ кода\n\n";
        
        for my $i (0..$#{$self->{sections}}) {
            my $section = $self->{sections}[$i];
            
            $doc .= "### " . ($section->{name} || "Секция " . ($i+1)) . "\n\n";
            
            if ($section->{description}) {
                $doc .= "$section->{description}\n\n";
            }
            
            if (@{$section->{commands}}) {
                $doc .= "#### Команды:\n\n";
                
                for my $cmd (@{$section->{commands}}) {
                    my $type_icon = $self->_get_type_icon($cmd->{type});
                    $doc .= "**$type_icon $cmd->{description}**\n\n";
                    $doc .= "```bash\n$cmd->{original}\n```\n\n";
                    
                    if ($cmd->{explanation}) {
                        $doc .= "*$cmd->{explanation}*\n\n";
                    }
                    
                    $doc .= "---\n\n";
                }
            }
        }
    }
    
    $doc .= "##Примеры запуска\n\n";
    $doc .= "```bash\n";
    $doc .= "# Запуск скрипта\n";
    $doc .= "./$script_name\n\n";
    $doc .= "# Запуск с правами администратора (если требуется)\n";
    $doc .= "sudo ./$script_name\n\n";
    $doc .= "# Запуск в фоновом режиме\n";
    $doc .= "nohup ./$script_name &\n";
    $doc .= "```\n\n";
    
    # инфа о генерации
    $doc .= "---\n";
    $doc .= "*Документация автоматически сгенерирована с помощью Perl Shell Script Documentor*\n";
    
    return $doc;
}

sub _get_type_icon {
    my ($self, $type) = @_;
    
    my %icons = (
        'condition' => '🔍',
        'loop' => '🔄',
        'network' => '🌐',
        'filter' => '🔍',
        'processing' => '⚙️',
        'variable' => '📝',
        'output' => '📤',
        'command' => '⚡'
    );
    
    return $icons{$type} || '⚡';
}

# запуск
package main;
main();