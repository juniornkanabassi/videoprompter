import Foundation

/// The script a new library starts with. It doubles as the tour: a first-time user presents it and
/// reads it aloud, and each section asks them to try the feature it describes, so Voice, the
/// passage keys, stage directions and the camera are all met in the order they are needed.
/// Help > Getting Started Guide brings it back after it has been deleted.
enum WelcomeScript {
  static let title = "Welcome to Video Prompter"
  /// Set once a library has been offered the script, so deleting it is final until Help asks again.
  static let offeredKey = "welcomeScriptOffered"
  static let markdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > Choose **Present**, then **Start reading**. Reading does not record. To check your sound first, open **Tools**, then **Check sound…** under Microphone.

    Hello, and welcome. Pause whenever you like. [Look at the camera.]

    ## Choose how to read

    Voice follow keeps your place as you speak. Open **Tools**, then **Reading mode…** to choose Voice follow or Automatic scroll. Automatic scroll waits for your Start delay, normally three seconds. The Cancel button stops the countdown. If reading needs attention, choose **Check reading…** beside the status for instructions and an automatic-scroll fallback.

    ## Make yourself comfortable

    Open **Tools** for **Smaller text** and **Larger text**. **More text settings…** opens Reading settings for fonts, spacing, colours and teleprompter mirroring. Changes apply to all scripts. The Settings sidebar also has Reading presets.

    Click a word to read from there. The arrow keys move between passages when the script has focus. When paused, choose **Back to start** beside **Start reading** to try again without stopping a recording. Open **Tools**, then **Edit this script**. Choose **Save changes** when finished, or **Cancel editing** to keep the original.

    ## Camera and recording

    Choose **Show camera** before recording if only your script is showing. Under **Tools**, use **View** to choose Script only, Script and camera, or Camera view. **Choose camera…** selects your camera and **Framing guides…** helps you compose the picture.

    In the Exposure group, **Zebras** marks bright areas and **Check brightness · False colour** helps compare brightness. **More exposure settings…** explains what to look for and how to adjust your camera. **Bypass exposure aids** temporarily hides configured aids; **Restore exposure aids** brings them back. Neither enables a tool by itself.

    **Clean presenter view** hides the script, framing guides and exposure aids in the presenter only. The Second monitor window keeps its overlays.

    **More camera settings…** opens Camera & Recording. Its Camera section offers **Open Second monitor window** for a separate window showing the same camera and recording. Shoot setups in Settings, or **Shoot setups…** in Tools, lets you save, apply, rename and delete complete setups. After Apply, **Restore previous setup** returns to your previous choices.

    **Record** and **Start reading** are separate actions. Choose **Stop recording** when finished, then **Show saved take…** to review it, or **Show in Finder** to find the file. A saved take with problems has a review action. The library's **Recordings** button opens your takes.

    ## Your own scripts

    Choose **Paste Copied Text**, **New Script**, or **Import File…**. Imported Markdown stays linked to the original file. Changes in either place appear in the other.

    Headings, bold and italics work. You can delete this guide and bring it back using **Getting Started Guide** in Help.
    """
}
