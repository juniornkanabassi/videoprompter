import Foundation
import PrompterCore

/// The script a new library starts with. It doubles as the tour: a first-time user presents it and
/// reads it aloud, and each section asks them to try the feature it describes, so Voice, the
/// passage keys, stage directions and the camera are all met in the order they are needed.
/// Help > Getting Started Guide brings it back after it has been deleted.
enum WelcomeScript {
  static let title = "Welcome to Video Prompter"
  /// Set once a library has been offered the script, so deleting it is final until Help asks again.
  static let offeredKey = "welcomeScriptOffered"
  static let markdown = Features.recording ? recordingMarkdown : monitorMarkdown
  private static let monitorMarkdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > Click **Open presenter**, then **Start reading**. Choose **Pause** when you need a break. **Back to start** returns to the first word.

    Hello, and welcome. [Look at the camera.]

    ## Reading

    Press **Space** to pause. Choose **Set up the shot** to return to the camera.
    **Reading settings** under Pause changes the reading mode, font, size and spacing for your teleprompter. You can also find these in **Settings > Reading**.

    ## Set up the shot

    Choose **Camera** to select your camera. Under Shot, choose **Landscape**, **Vertical turned left** or **Vertical turned right**.
    The bar has **Camera**, **Zebras**, **False colour**, **Guides**, **Mic**, **Adjust** and **Clean**.
    Zebras, False colour, Guides and Mic switch their aids on or off. Choose **Adjust** to change settings. Right-click a tile to jump to its tab.
    Choose **Adjust > Mic**, select your microphone, then speak and watch the meter. For a microphone test, choose **Settings > Microphone > Test microphone**.

    ## Check exposure

    Choose your skin tone in **Adjust > False colour**. The **Exposure key** explains the colours.
    For a **Grey card check**, hold a grey card where your face will be. Adjust exposure until it turns green. Choose **Finish grey card check** to return to your skin settings.

    ## Clean view

    **Clean** shows only the picture and pauses reading. Move the pointer to see **Exit Clean**. Press **Escape** to leave Clean. Escape also returns from reading to **Set up the shot**.

    ## Your scripts

    Choose **Paste script**, **New script** or **Import file…**. Your library saves edits automatically.
    You can bring this guide back using **Getting Started Guide** in Help.
    """
  private static let recordingMarkdown = """
    # Welcome to Video Prompter

    > [!note] Start here
    > Choose **Present**, then **Start reading**. Reading does not record. To check your sound first, open **Tools**, choose Microphone in **Tools section**, then **Check sound…**.

    Hello, and welcome. Pause whenever you like. [Look at the camera.]

    ## Choose how to read

    Voice follow keeps your place as you speak. Open **Tools**, choose Text, then **Reading mode…** to choose Voice follow or Automatic scroll. Automatic scroll waits for your Start delay, normally three seconds. The Cancel button stops the countdown. If reading needs attention, choose **Check reading…** beside the status for instructions and an automatic-scroll fallback.

    ## Make yourself comfortable

    Open **Tools** for **Smaller text** and **Larger text**. **More text settings…** opens Reading settings for fonts, spacing, colours and teleprompter mirroring. Changes apply to all scripts. Reading settings also include Reading presets.

    Click a word to read from there. The arrow keys move between passages when the script has focus. When paused, choose **Back to start** beside **Start reading** to try again without stopping a recording. Open **Tools**, then **Edit this script**. Choose **Save changes** when finished, or **Cancel editing** to keep the original.

    ## Camera and recording

    Choose **Show camera** before recording if only your script is showing. Under **Tools**, choose Camera in **Tools section**, then use **View** to choose Script only, Script and camera, or Camera view. **Choose camera…** selects your camera and **Framing guides…** helps you compose the picture.

    In the Exposure section of **Tools**, the zebra check marks bright areas and **Check brightness · False colour** helps compare brightness. **More exposure settings…** explains what to look for and how to adjust your camera. Under the camera, **Zebras**, **False colour**, **Guides**, **Mic level** and **Clean** switch each aid off and on without changing your saved choices, and the arrow beside one opens its settings. **Camera** opens the camera list.

    To retake a line, press Pause, click the word, then Start reading. The recording keeps going.

    **Clean presenter view** hides the script, framing guides and exposure aids in the presenter only. The Second monitor window keeps its overlays.

    **More camera settings…** opens Camera & Recording. Its Camera section offers **Open Second Monitor Window** for a separate window showing the same camera and recording. Shoot setups in Settings, or **Shoot setups…** under Tools, lets you save, apply, rename and delete complete setups. After Apply, **Restore Previous Setup** returns to your previous choices.

    **Record** and **Start reading** are separate actions. Choose **Stop recording** when finished, then **Play** to review it, or **Show in Finder** to find the file. A saved take with problems has a review action. The library's **Recordings** button opens your takes.

    ## Your own scripts

    Choose **Paste Copied Text**, **New Script**, or **Import File…**. Imported Markdown stays linked to the original file. Changes in either place appear in the other.

    Headings, bold and italics work. You can delete this guide and bring it back using **Getting Started Guide** in Help.
    """
}
