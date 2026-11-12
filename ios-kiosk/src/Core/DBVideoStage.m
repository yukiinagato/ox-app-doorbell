#import "DBVideoStage.h"

#include <math.h>

CGSize DBVideoStageUprightSize(CGSize source, NSInteger rotation) {
  NSInteger turn = ((rotation % 360) + 360) % 360;
  if (turn == 90 || turn == 270) return CGSizeMake(source.height, source.width);
  return source;
}

CGSize DBVideoStageFitSize(CGSize stage, CGSize source, NSInteger rotation) {
  CGSize upright = DBVideoStageUprightSize(source, rotation);
  if (stage.width <= 0 || stage.height <= 0 || upright.width <= 0 || upright.height <= 0)
    return CGSizeZero;
  CGFloat scale = MIN(stage.width / upright.width, stage.height / upright.height);
  return CGSizeMake((CGFloat)floor(upright.width * scale), (CGFloat)floor(upright.height * scale));
}

DBVideoStageAxis DBVideoStageAxisMake(CGFloat stageLength, CGFloat zoomedLength) {
  DBVideoStageAxis axis;
  stageLength = MAX(0, stageLength);
  zoomedLength = MAX(0, zoomedLength);
  if (zoomedLength <= stageLength) {
    axis.inset = (stageLength - zoomedLength) / 2;
    axis.minOffset = -axis.inset;
    axis.maxOffset = -axis.inset;
    axis.visible = zoomedLength;
  } else {
    axis.inset = 0;
    axis.minOffset = 0;
    axis.maxOffset = zoomedLength - stageLength;
    axis.visible = stageLength;
  }
  return axis;
}

CGFloat DBVideoStageClampOffset(DBVideoStageAxis axis, CGFloat offset) {
  return MIN(axis.maxOffset, MAX(axis.minOffset, offset));
}
