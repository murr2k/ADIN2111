# GitHub Actions Workflows

This directory contains CI/CD pipelines for the ADIN2111 Linux driver project.

## Workflows

### 1. Build Validation (`build.yml`)
**Status**: ✅ Implemented (Phase 1)

**Purpose**: Validates that the driver compiles successfully across multiple kernel versions and compiler combinations.

**Triggers**:
- Push to main, develop, or feature branches
- Pull requests to main
- Manual dispatch

**Matrix Testing**:
- Kernel versions: 5.10, 5.15, 6.1, 6.5, 6.6*, 6.8, latest
- GCC versions: 9, 11, 12
- Total combinations: 19 (with exclusions)
*Note: 6.6 falls back to 6.5 if not available in Ubuntu repos

**Checks**:
- Module compilation
- Warning detection (threshold: 5)
- Test module building
- Module information verification

### 2. Code Quality (`code-quality.yml`)
**Status**: 🔄 Planned (Phase 2)

**Purpose**: Static code analysis and style checking

**Tools**:
- checkpatch.pl
- sparse
- cppcheck
- clang-format

### 3. Test Execution (`test.yml`)
**Status**: 🔄 Planned (Phase 3)

**Purpose**: Run unit tests and integration tests

**Coverage**:
- Kernel module tests
- User-space utilities
- Network functionality

### 4. Performance Benchmarks (`benchmark.yml`)
**Status**: 🔄 Planned (Phase 4)

**Purpose**: Performance regression testing

**Metrics**:
- Latency measurements
- Throughput benchmarks
- CPU usage monitoring

### 5. Hardware Testing (`hardware-test.yml`)
**Status**: 🔄 Planned (Phase 5)

**Purpose**: Hardware-in-loop validation (self-hosted runner)

## Badges

Add to README.md:
```markdown
![Build Status](https://github.com/murr2k/ADIN2111/actions/workflows/build.yml/badge.svg)
```

## Manual Workflow Triggers

All workflows support manual dispatch via GitHub UI:
1. Go to Actions tab
2. Select workflow
3. Click "Run workflow"
4. Select branch and parameters

## Artifacts

Build artifacts are retained for 7 days and include:
- Compiled kernel modules (*.ko)
- Build logs
- Warning reports

## Contributing

When adding new workflows:
1. Test locally with `act` if possible
2. Create feature branch
3. Test in fork before PR
4. Update this README

## Support

For CI/CD issues, check:
- [GitHub Actions Documentation](https://docs.github.com/actions)
- [Issue #1](https://github.com/murr2k/ADIN2111/issues/1) for implementation details