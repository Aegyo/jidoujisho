import 'package:flutter/material.dart';

/// A helper for creating a [DropdownButton] styled for the application.
class JidoujishoDropdown<T> extends StatefulWidget {
  /// Define a dropdown with options and an action to do when the selected
  /// option is changed.
  const JidoujishoDropdown({
    required this.options,
    required this.initialOption,
    required this.generateLabel,
    required this.onChanged,
    Key? key,
  }) : super(key: key);

  /// List of options that are available to pick from.
  final List<T> options;

  /// An option that will appear as default when this dropdown appears for the
  /// first time. Must be an option available in [options].
  final T initialOption;

  /// A function that converts a [T] to a usable label.
  final String Function(T) generateLabel;

  /// A callback that will occur when a new option has been selected.
  final Function(T?) onChanged;

  @override
  State<JidoujishoDropdown<T>> createState() => _JidoujishoDropdownState<T>();
}

class _JidoujishoDropdownState<T> extends State<JidoujishoDropdown<T>> {
  late T? selectedOption;

  @override
  void initState() {
    selectedOption = widget.initialOption;
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        DropdownButton<T>(
          isExpanded: true,
          underline: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.fromBorderSide(
                BorderSide(
                  width: 0.5,
                  color:
                      Theme.of(context).unselectedWidgetColor.withOpacity(0.5),
                ),
              ),
            ),
          ),
          value: selectedOption,
          items: widget.options.map((value) {
            String text = widget.generateLabel(value);
            return DropdownMenuItem<T>(
              value: value,
              child: Text('  $text'),
            );
          }).toList(),
          onChanged: (newOption) async {
            widget.onChanged(newOption);

            setState(() {
              selectedOption = newOption;
            });
          },
        ),

        /// Used to always show the underline.
        Container(height: 0.1, color: Colors.transparent),
      ],
    );
  }
}
