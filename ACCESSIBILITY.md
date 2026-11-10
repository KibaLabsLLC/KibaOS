Accessibility

KibaOS is designed to provide a simple, refined, and accessible computing experience. We believe that operating systems should be usable by everyone, regardless of their abilities, experience, or preferred way of interacting with a computer.

Accessibility is an important part of KibaOS development, not an optional feature. We aim to make the desktop, installer, system settings, applications, and documentation usable by as many people as possible.

This document outlines our accessibility priorities, expectations for contributors, and the process for reporting accessibility barriers.

Priorities

KibaOS prioritizes the following areas of accessibility:

* Keyboard navigation: Users should be able to navigate the desktop, installer, settings, and other system interfaces without requiring a mouse.
* Screen readers: Interface elements should expose meaningful labels, roles, and descriptions wherever supported.
* Visual accessibility: We aim to provide readable typography, sufficient contrast, scalable interface elements, and support for reduced visual strain.
* Motor accessibility: Interactive elements should have reasonable target sizes and avoid requiring unnecessarily precise movements.
* Cognitive accessibility: Interfaces should remain predictable, consistent, understandable, and free of unnecessary complexity.
* Language accessibility: System interfaces and documentation should support localization and clear, understandable language.
* Audio accessibility: Important system notifications should not rely exclusively on sound.

We aim to work toward WCAG 2.2 Level AA principles where applicable to KibaOS interfaces. This is an aspirational development target, not a claim of verified conformance.

Contributor expectations

All contributors are encouraged to consider accessibility when introducing or modifying user-facing features.

Contributors should:

* Preserve keyboard accessibility when modifying interface components.
* Use descriptive labels for buttons, controls, and interactive elements.
* Avoid relying exclusively on color, sound, or visual indicators to communicate information.
* Maintain sufficient text contrast and readable interface sizing.
* Consider screen reader compatibility when introducing new interface elements.
* Avoid unnecessary animations or provide alternatives where practical.
* Document accessibility-related limitations introduced by new features.

Changes affecting user-facing interfaces should include relevant testing information in their pull requests.

Accessibility improvements are welcome at every level, including documentation, desktop components, system utilities, and installation workflows.

Reporting accessibility issues

Accessibility barriers can be reported through the official KibaOS GitHub issue tracker:

https://github.com/KibaLabsLLC/KibaOS/issues

When reporting an issue, include as much relevant information as possible:

* The affected feature or application.
* What you were attempting to accomplish.
* What happened instead.
* Your KibaOS version and relevant system information.
* Any assistive technology or input method involved.

Screenshots, recordings, and additional diagnostic information are welcome but entirely optional.

You do not need to disclose a disability or provide personal medical information when reporting an accessibility issue.

Severity

Accessibility issues may be categorized by their impact:

* Critical: A significant barrier prevents users from accessing or completing an essential system function, with no reasonable workaround.
* High: A major accessibility barrier substantially limits the use of an important feature.
* Moderate: A feature remains usable, but certain interactions are difficult or require a workaround.
* Low: Minor accessibility inconsistencies, visual issues, or improvements that would make the experience more comfortable.

Maintainers may assign or adjust severity during issue triage.

How we respond

Kiba Labs aims to:

* Review accessibility reports alongside other software issues.
* Acknowledge reports when maintainers are available.
* Investigate reported barriers and determine their impact.
* Provide known workarounds where possible.
* Communicate relevant progress through the associated issue.
* Allow reporters to verify fixes when practical.

Resolution times depend on the complexity of the issue, its severity, and available development resources. We do not guarantee fixed resolution deadlines.

Ownership and maintenance

Accessibility is a shared responsibility across KibaOS development.

Kiba Labs, LLC maintains responsibility for accessibility direction, reviewing reported issues, and encouraging accessibility-conscious development practices.

Project maintainers are responsible for considering accessibility in the components they maintain and reviewing relevant contributions.

This statement will be reviewed periodically and updated as KibaOS develops, accessibility support changes, and new limitations are identified.

Supported environments

KibaOS is primarily developed for UEFI-based desktop and laptop systems.

Accessibility support depends on the underlying desktop environment, system components, installed applications, and available assistive technologies.

We aim to support:

* Keyboard and mouse input.
* Standard display scaling and resolution adjustments where supported.
* Available Linux accessibility interfaces and assistive technologies.
* Localized system interfaces where translations are available.

Specific combinations of assistive technologies, hardware, and desktop components may have incomplete or unverified support.

We will update this section as additional environments are tested.

Known limitations

KibaOS is actively developed, and accessibility support may vary between releases.

Potential limitations include:

* Some custom desktop components may not expose complete accessibility information.
* Screen reader support may vary between applications and system interfaces.
* Certain installer or first-boot interactions may not yet provide equivalent keyboard or assistive technology access.
* Some third-party applications may have accessibility limitations outside Kiba Labs’ control.

Known issues should be documented in the issue tracker as they are identified.

We do not claim that KibaOS is currently free of accessibility barriers.

Feedback and improvements

Accessibility is an ongoing process, and feedback from users and contributors is important to improving KibaOS.

Suggestions for improving this statement or KibaOS accessibility practices are welcome through the KibaOS GitHub issue tracker:

https://github.com/KibaLabsLLC/KibaOS/issues

We encourage anyone who encounters an accessibility barrier to report it. Every report helps us identify areas where KibaOS can become more usable.

Kiba Labs, LLC

Simple. Refined. Libre.
