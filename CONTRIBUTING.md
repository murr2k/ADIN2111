# Contributing to ADIN2111 Linux Driver

**Author:** Murray Kopit  
**Date:** August 11, 2025

Thank you for your interest in contributing to the ADIN2111 Linux Driver project!

## Code of Conduct

This project follows the Linux kernel community standards. Be respectful, professional, and constructive in all interactions.

## How to Contribute

### Reporting Issues

1. Check existing issues to avoid duplicates
2. Use the issue template when available
3. Include:
   - Kernel version
   - Hardware configuration
   - Steps to reproduce
   - Expected vs actual behavior
   - Relevant logs (dmesg, kernel logs)

### Submitting Code

1. **Fork the repository**
   ```bash
   git clone https://github.com/murr2k/ADIN2111.git
   cd ADIN2111
   ```

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Follow coding standards**
   - Linux kernel coding style (checkpatch.pl clean)
   - Meaningful commit messages
   - One logical change per commit

4. **Test your changes**
   ```bash
   cd tests/
   sudo ./scripts/automation/run_all_tests.sh
   ```

5. **Submit a Pull Request**
   - Clear description of changes
   - Reference any related issues
   - Include test results

## Development Guidelines

### Code Style

Follow the Linux kernel coding style:
```bash
# Check your code
scripts/checkpatch.pl --no-tree -f your_file.c

# Format code
indent -linux your_file.c
```

### Commit Messages

Format:
```
subsystem: Brief description (50 chars max)

Detailed explanation of the change. Wrap at 72 characters.
Explain the problem being solved and how this commit solves it.

Signed-off-by: Your Name <your.email@example.com>
```

Example:
```
adin2111: Add support for jumbo frames

Enable jumbo frame support up to 9000 bytes by modifying the
MAX_FRAME_SIZE register and adjusting buffer allocations.
This improves throughput for large packet workloads.

Tested on: ADIN2111 Rev B hardware
Signed-off-by: Jane Developer <jane@example.com>
```

### Testing Requirements

All contributions must:
1. Pass existing tests
2. Include new tests for new features
3. Not reduce code coverage
4. Be tested on actual hardware (if possible)

### Documentation

- Update relevant documentation
- Add inline comments for complex logic
- Update README.md if adding features
- Document new module parameters or sysfs entries

## Areas for Contribution

### Priority Areas

1. **Performance Optimization**
   - DMA support implementation
   - Interrupt coalescing
   - Zero-copy improvements

2. **Feature Additions**
   - Advanced VLAN support
   - Traffic shaping/QoS
   - Hardware timestamping

3. **Platform Support**
   - Additional architectures (RISC-V, etc.)
   - Embedded platform optimizations

4. **Testing**
   - Fuzzing test cases
   - Performance regression tests
   - Power management tests

### Good First Issues

Look for issues labeled `good-first-issue` for beginner-friendly tasks.

## Review Process

1. Automated CI runs on all PRs
2. Code review by maintainers
3. Testing on reference hardware
4. Merge after approval

## Communication

- **Issues**: Bug reports and feature requests
- **Discussions**: General questions and ideas
- **Email**: murr2k@gmail.com for private concerns

## Recognition

Contributors will be:
- Listed in CONTRIBUTORS file
- Mentioned in release notes
- Given credit in commit history

## Legal

By contributing, you agree that your contributions will be licensed under GPL v2+.

## Questions?

Feel free to open an issue for any questions about contributing.

Thank you for helping improve the ADIN2111 Linux Driver!