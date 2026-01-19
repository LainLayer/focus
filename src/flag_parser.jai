/*
    How to use this function.

    ```
    my_flags: struct {
        enable_something:    bool;     @"Enable the thing"
        name_of_something:   string;   @"Name of the thing"
        amount_of_something: s64 = -1; @"Amount of thing"
    };

    args := get_command_line_arguments();

    // needs to be freed
    non_flag_arguments := parse_command_line_flags(
        *my_flags,
        array_view(args, 1, args.count - 1), // skip argv[0]
        (error: string) { do_something_about_error(error); },
        "My epic program\n\n"
    );
    ```

    Non-bool arguments are flag only, they dont take a value.

    At the end of the function, the original flag struct will be
    set to the parsed values if they were present. Otherwise the fields
    will remain in their default values;

    Any flags that fail to parse will get skipped and `on_error` will be called.

    Only calling `--help` exits the program.
*/

parse_command_line_flags :: (flag_struct: *$T, arguments: []string, on_error: (error_text: string), help_banner: string) -> non_flag_arguments: []string
#modify {
    ti := cast(*Type_Info, T);

    if ti.type != .STRUCT
        return false, "flag_struct has to be a pointer to a struct";

    struct_info := cast(*Type_Info_Struct, T);

    for struct_info.members {
        if it.type.type == {
            case .BOOL;   #through;
            case .INTEGER;#through;
            case .STRING;
                /* allowed */
            case;
                return false, tprint("flag_struct member % is of an unsupported type %", it.name, it.type.type);
        }
    }

    return true;
}
{
    flag_struct_info :: type_info(T);
    help_text        :: #run generate_help_text(flag_struct_info);

    flags_seen:         [..]string; defer array_free(flags_seen);
    non_flag_arguments: [..]string;

    args := arguments;

    while true {
        auto_release_temp();

        ate, flag := eat_flag(*args);
        if !ate break;

        if !begins_with(flag, "-") {
            array_add(*non_flag_arguments, flag);
            continue;
        }

        normalized_flag := normalize_flag(flag);

        found := false;
        if array_find(built_in_help_aliases, normalized_flag) {
            found = true;
        } else {
            for flag_struct_info.members {
                if it.name == normalized_flag {
                    found = true;
                    break;
                }
            }
        }

        if !found {
            on_error(tprint("Unknown command line parameter '%'.", flag));
            continue;
        }

        if !array_add_if_unique(*flags_seen, normalized_flag) {
            on_error(tprint("Command line parameter '%' passed twice. All but the first one were ignored.", flag));
            continue;
        }

        #insert #run generate_flag_switch_case(flag_struct_info);
    }

    return non_flag_arguments;
}

#scope_file

// This is not yet used, but its here in case we wanna have some special flag metadata. Required is a placeholder. I doubt a text editor
// will have required flags.
//
reserved_note_names :: string.["Required"];

built_in_help_aliases :: string.["help", "usage", "h", "?"];

max_length_of_built_in_help_aliases :: #run -> s64 {
    result := -999;
    for built_in_help_aliases
        result = max(result, it.count);
    return result;
};

generate_help_text :: (info: *Type_Info_Struct) -> string {
    auto_release_temp();

    builder: String_Builder;

    max_flag_width := max_length_of_built_in_help_aliases;
    for info.members
        max_flag_width = max(max_flag_width, it.name.count + get_member_typed_argument(*it).count);

    push_flag :: (builder: *String_Builder, name: string, description: string, max_flag_width: s64) {
        print_to_builder(builder, "    -%", replace(name, "_", "-",, temp));

        for 0..(max_flag_width - name.count)
            append(builder, " ");

        append(builder, description);
        append(builder,  "\n");
    }

    for info.members {
        description := "";

        for note : it.notes {
            if !array_find(reserved_note_names, note) {
                description = note;
                break;
            }
        }

        push_flag(*builder, tprint("%%", it.name, get_member_typed_argument(*it)), description, max_flag_width);
    }

    push_flag(*builder, "help",  "prints this text", max_flag_width);

    return builder_to_string(*builder);
}

get_member_typed_argument :: (info: *Type_Info_Struct_Member) -> string {
    if info.type.type == {
        case .STRING;  return " <string>";
        case .INTEGER; return " <number>";
        case .BOOL;    return "";
        case;
            assert(false, tprint("Unimplemented flag type % for field %", info.type.type, info.name));
            return ""; // jai currently doesnt detect noreturn functions.
    }
}

eat_flag :: (flags: *[]string) -> bool, string {
    if flags.count == 0 return false, "";

    result      := flags.*[0];
    flags.count -= 1;
    flags.data  += 1;

    return true, result;
}

normalize_flag :: (flag: string) -> string {
    result := flag;

    // Yes this means `-------flag` will work. I think this is fine.
    while result.count > 0 && begins_with(result, "-")
        result = slice(result, 1, result.count - 1);

    return replace(result, "-", "_",, temp);
}

generate_flag_switch_case :: (info: *Type_Info_Struct) -> string {
    // Sadly in jai currently its not possible to #insert into the middle of an existing switch case
    // so we have to generate the whole switch case as a string.
    // - January 18th, 2026
    //
    builder: String_Builder;
    append(*builder, "if normalized_flag == {\n");

    for info.members
        print_to_builder(*builder, "    case \"%1\"; eat_flag_into_field(\"%1\", *args, *flag_struct.%1, on_error);\n", it.name);

    // Can never guess with command line utilities...
    for built_in_help_aliases {
        print_to_builder(*builder, "    case \"%\";", it);

        if it_index < built_in_help_aliases.count - 1
            append(*builder, " #through;\n");
        else
            append(*builder, "\n");
    }

    footer :: #string JAI
        log("%\n", help_banner);
        log("flags:");
        log(help_text);
        exit(0);
    JAI;

    append(*builder, footer);
    append(*builder, "}\n");

    return builder_to_string(*builder);
}

eat_flag_into_field :: ($flag_name: string, flags: *[]string, field: *$T, on_error: (error_text: string)) {
    auto_release_temp();

    ti :: type_info(T);

    #if ti.type == .INTEGER {
            ate, next_flag := eat_flag(flags);

            if !ate {
                on_error(tprint("Command line parameter '%' expects a numeric value but none was given.", flag_name));
                return;
            }

            int_value, success := parse_int(*copy_string(next_flag,, temp), T, "");

            if !success {
                on_error(tprint("Command line parameter '%' expects a numeric value but we got '%' and could not parse it as a number.", flag_name, next_flag));
                return;
            }

            field.* = int_value;

    } else #if ti.type == .STRING {
            ate, next_flag := eat_flag(flags);

            if !ate {
                on_error(tprint("Command line parameter '%' expects a string value but none was given.", flag_name));
                return;
            }

            field.* = next_flag;

    } else #if ti.type == .BOOL {
            field.* = true;
    } else {
            assert(false, tprint("Unimplemented flag type % for field %", T, flag_name));
    }
}
